//! Local verification of the OS account. The password is checked on this
//! machine only and must never be logged, stored or sent anywhere.

pub fn current_username() -> String {
    crate::common::username()
}

/// Verifies `password` for the local `username`.
///
/// Failures are reported as a plain `false` without distinguishing an unknown
/// account from a wrong password, so the caller cannot be used to enumerate
/// local accounts.
pub fn verify(username: &str, password: &str) -> bool {
    let username = username.trim();
    if username.is_empty() || password.is_empty() {
        return false;
    }
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        pam_verify(username, password)
    }
    #[cfg(windows)]
    {
        win_verify(username, password)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        let _ = (username, password);
        false
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn pam_verify(username: &str, password: &str) -> bool {
    // `tensordesk` is the service shipped with the package; `login` keeps the
    // client working on machines where that file was not installed.
    for service in ["tensordesk", "login"] {
        if service == "tensordesk"
            && !std::path::Path::new("/etc/pam.d/tensordesk").exists()
        {
            continue;
        }
        if unix_pam::verify(service, username, password) {
            return true;
        }
    }
    false
}

// PAM is reached through `dlopen` rather than a build-time dependency: the
// headers are not part of every build image, and the ABI is stable.
#[cfg(any(target_os = "linux", target_os = "macos"))]
mod unix_pam {
    use libc::{c_char, c_int, c_void};
    use libloading::Library;
    use std::ffi::CString;
    use std::ptr;

    type PamHandle = *mut c_void;

    const PAM_SUCCESS: c_int = 0;
    const PAM_CONV_ERR: c_int = 19;
    const PAM_BUF_ERR: c_int = 5;
    const PAM_PROMPT_ECHO_OFF: c_int = 1;
    const PAM_PROMPT_ECHO_ON: c_int = 2;
    const PAM_ERROR_MSG: c_int = 3;

    #[repr(C)]
    struct PamMessage {
        msg_style: c_int,
        msg: *const c_char,
    }

    #[repr(C)]
    struct PamResponse {
        resp: *mut c_char,
        resp_retcode: c_int,
    }

    #[repr(C)]
    struct PamConv {
        conv: Option<
            unsafe extern "C" fn(
                c_int,
                *mut *const PamMessage,
                *mut *mut PamResponse,
                *mut c_void,
            ) -> c_int,
        >,
        appdata_ptr: *mut c_void,
    }

    type PamStart = unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        *const PamConv,
        *mut PamHandle,
    ) -> c_int;
    type PamAuthenticate = unsafe extern "C" fn(PamHandle, c_int) -> c_int;
    type PamEnd = unsafe extern "C" fn(PamHandle, c_int) -> c_int;

    struct Credentials {
        username: CString,
        password: CString,
    }

    unsafe extern "C" fn converse(
        num_msg: c_int,
        msg: *mut *const PamMessage,
        out_resp: *mut *mut PamResponse,
        appdata: *mut c_void,
    ) -> c_int {
        if num_msg <= 0 || msg.is_null() || out_resp.is_null() || appdata.is_null() {
            return PAM_CONV_ERR;
        }
        // PAM frees every response, so they must be heap allocated here.
        let responses = libc::calloc(num_msg as usize, std::mem::size_of::<PamResponse>())
            as *mut PamResponse;
        if responses.is_null() {
            return PAM_BUF_ERR;
        }
        let creds = &*(appdata as *const Credentials);
        let mut result = PAM_SUCCESS;
        for i in 0..num_msg as isize {
            let message = *msg.offset(i);
            if message.is_null() {
                result = PAM_CONV_ERR;
                break;
            }
            let response = responses.offset(i);
            match (*message).msg_style {
                PAM_PROMPT_ECHO_OFF => {
                    (*response).resp = libc::strdup(creds.password.as_ptr());
                }
                PAM_PROMPT_ECHO_ON => {
                    (*response).resp = libc::strdup(creds.username.as_ptr());
                }
                PAM_ERROR_MSG => {
                    result = PAM_CONV_ERR;
                    break;
                }
                _ => {}
            }
        }
        if result == PAM_SUCCESS {
            *out_resp = responses;
        } else {
            for i in 0..num_msg as isize {
                let response = responses.offset(i);
                if !(*response).resp.is_null() {
                    libc::free((*response).resp as *mut c_void);
                }
            }
            libc::free(responses as *mut c_void);
        }
        result
    }

    pub fn verify(service: &str, username: &str, password: &str) -> bool {
        let Ok(user) = CString::new(username) else {
            return false;
        };
        let Ok(pass) = CString::new(password) else {
            return false;
        };
        let Ok(svc) = CString::new(service) else {
            return false;
        };
        let creds = Credentials {
            username: user,
            password: pass,
        };
        let conv = PamConv {
            conv: Some(converse),
            appdata_ptr: &creds as *const _ as *mut c_void,
        };
        for name in [
            "libpam.so.0",
            "libpam.so",
            "libpam.2.dylib",
            "/usr/lib/libpam.2.dylib",
        ] {
            // SAFETY: the library is kept alive for the whole conversation.
            let Ok(lib) = (unsafe { Library::new(name) }) else {
                continue;
            };
            // SAFETY: the symbols are declared with the PAM C ABI above.
            let (Ok(start), Ok(authenticate), Ok(end)) = (unsafe {
                (
                    lib.get::<PamStart>(b"pam_start\0"),
                    lib.get::<PamAuthenticate>(b"pam_authenticate\0"),
                    lib.get::<PamEnd>(b"pam_end\0"),
                )
            }) else {
                continue;
            };
            let mut handle: PamHandle = ptr::null_mut();
            // SAFETY: `lib` is alive for the whole conversation, the
            // conversation struct and `creds` outlive the calls, and PAM owns
            // the responses allocated by `converse`.
            unsafe {
                if start(svc.as_ptr(), creds.username.as_ptr(), &conv, &mut handle)
                    != PAM_SUCCESS
                {
                    return false;
                }
                let code = authenticate(handle, 0);
                end(handle, code);
                return code == PAM_SUCCESS;
            }
        }
        false
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
fn split_account(input: &str) -> (String, String) {
    if let Some((domain, user)) = input.split_once('\\') {
        let domain = if domain.is_empty() { "." } else { domain };
        (user.to_string(), domain.to_string())
    } else {
        // A UPN is passed as-is; LogonUserW uses "." for the local domain.
        (input.to_string(), ".".to_string())
    }
}

#[cfg(windows)]
fn win_verify(username: &str, password: &str) -> bool {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::Security::{
        LogonUserW, LOGON32_LOGON_NETWORK, LOGON32_PROVIDER_DEFAULT,
    };
    let (user, domain) = split_account(username);
    let mut token = HANDLE::default();
    let ok = unsafe {
        LogonUserW(
            &HSTRING::from(user),
            &HSTRING::from(domain),
            &HSTRING::from(password),
            LOGON32_LOGON_NETWORK,
            LOGON32_PROVIDER_DEFAULT,
            &mut token,
        )
    }
    .is_ok();
    if ok {
        unsafe {
            let _ = CloseHandle(token);
        }
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_account_variants() {
        assert_eq!(
            split_account("CORP\\alice"),
            ("alice".to_string(), "CORP".to_string())
        );
        assert_eq!(
            split_account("alice@corp.example"),
            ("alice@corp.example".to_string(), ".".to_string())
        );
        assert_eq!(
            split_account("alice"),
            ("alice".to_string(), ".".to_string())
        );
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn pam_path_returns_false_for_unknown_user() {
        assert!(!verify("tensordesk_no_such_user", "wrong-password"));
    }

    #[test]
    fn rejects_empty_input() {
        assert!(!verify("", "secret"));
        assert!(!verify("   ", "secret"));
        assert!(!verify("alice", ""));
    }
}
