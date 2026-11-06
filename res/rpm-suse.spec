Name:       tensordesk
Version:    1.1.9
Release:    0
Summary:    RPM package
License:    GPL-3.0
Requires:   gtk3 libxcb1 libXfixes3 alsa-utils libXtst6 libva2 gstreamer-plugins-base gstreamer-plugin-pipewire
Recommends: libayatana-appindicator3-1 xdotool

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

%global __python %{__python3}

%install
mkdir -p %{buildroot}/usr/bin/
mkdir -p %{buildroot}/usr/share/tensordesk/
mkdir -p %{buildroot}/usr/share/tensordesk/files/
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps/
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps/
install -m 755 $HBB/target/release/tensordesk %{buildroot}/usr/bin/tensordesk
install $HBB/libsciter-gtk.so %{buildroot}/usr/share/tensordesk/libsciter-gtk.so
install $HBB/res/tensordesk.service %{buildroot}/usr/share/tensordesk/files/
install $HBB/res/128x128@2x.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/tensordesk.png
install $HBB/res/scalable.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/tensordesk.svg
install $HBB/res/tensordesk.desktop %{buildroot}/usr/share/tensordesk/files/
install $HBB/res/tensordesk-link.desktop %{buildroot}/usr/share/tensordesk/files/

%files
/usr/bin/tensordesk
/usr/share/tensordesk/libsciter-gtk.so
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
    rm /usr/share/applications/tensordesk.desktop || true
    rm /usr/share/applications/tensordesk-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
  ;;
esac
