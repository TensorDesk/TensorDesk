Name:       tensordesk
Version:    1.5.1
Release:    0
Summary:    RPM package
License:    GPL-3.0
URL:        https://rustdesk.com
Vendor:     rustdesk <info@rustdesk.com>
Requires:   gtk3 libxcb libXfixes alsa-lib libva gstreamer1-plugins-base
Recommends: libayatana-appindicator-gtk3 libxdo
Provides:   libdesktop_drop_plugin.so()(64bit), libdesktop_multi_window_plugin.so()(64bit), libfile_selector_linux_plugin.so()(64bit), libflutter_custom_cursor_plugin.so()(64bit), libflutter_linux_gtk.so()(64bit), libscreen_retriever_plugin.so()(64bit), libtray_manager_plugin.so()(64bit), liburl_launcher_linux_plugin.so()(64bit), libwindow_manager_plugin.so()(64bit), libwindow_size_plugin.so()(64bit), libtexture_rgba_renderer_plugin.so()(64bit)

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

# %global __python %{__python3}

%install

mkdir -p "%{buildroot}/usr/share/tensordesk" && cp -r ${HBB}/flutter/build/linux/x64/release/bundle/* -t "%{buildroot}/usr/share/tensordesk"
mkdir -p "%{buildroot}/usr/bin"
install -Dm 644 $HBB/res/tensordesk.service -t "%{buildroot}/usr/share/tensordesk/files"
install -Dm 644 $HBB/res/tensordesk.desktop -t "%{buildroot}/usr/share/tensordesk/files"
install -Dm 644 $HBB/res/tensordesk-link.desktop -t "%{buildroot}/usr/share/tensordesk/files"
install -Dm 644 $HBB/res/128x128@2x.png "%{buildroot}/usr/share/icons/hicolor/256x256/apps/tensordesk.png"
install -Dm 644 $HBB/res/scalable.svg "%{buildroot}/usr/share/icons/hicolor/scalable/apps/tensordesk.svg"

%files
/usr/share/tensordesk/*
/usr/share/tensordesk/files/tensordesk.service
/usr/share/icons/hicolor/256x256/apps/tensordesk.png
/usr/share/icons/hicolor/scalable/apps/tensordesk.svg
/usr/share/tensordesk/files/tensordesk.desktop
/usr/share/tensordesk/files/tensordesk-link.desktop

%changelog
# let's skip this for now

%pre
# can do something for centos7
case "$1" in
  1)
    # for install
  ;;
  2)
    # for upgrade
    systemctl stop tensordesk || true
  ;;
esac

%post
cp /usr/share/tensordesk/files/tensordesk.service /etc/systemd/system/tensordesk.service
cp /usr/share/tensordesk/files/tensordesk.desktop /usr/share/applications/
cp /usr/share/tensordesk/files/tensordesk-link.desktop /usr/share/applications/
ln -sf /usr/share/tensordesk/tensordesk /usr/bin/tensordesk
systemctl daemon-reload
systemctl enable tensordesk
systemctl start tensordesk
update-desktop-database

%preun
case "$1" in
  0)
    # for uninstall
    systemctl stop tensordesk || true
    systemctl disable tensordesk || true
    rm /etc/systemd/system/tensordesk.service || true
  ;;
  1)
    # for upgrade
  ;;
esac

%postun
case "$1" in
  0)
    # for uninstall
    rm /usr/bin/tensordesk || true
    rmdir /usr/lib/tensordesk || true
    rmdir /usr/local/tensordesk || true
    rmdir /usr/share/tensordesk || true
    rm /usr/share/applications/tensordesk.desktop || true
    rm /usr/share/applications/tensordesk-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
    rmdir /usr/lib/tensordesk || true
    rmdir /usr/local/tensordesk || true
  ;;
esac
