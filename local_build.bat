@echo off
set PATH=C:\src\flutter\bin;%PATH%
set ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk
set PATH=%PATH%;%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\cmdline-tools\latest\bin

cd C:\Kotteg_OpenCode_Test\VakhtovikPlayer\client\flutter_app
flutter build apk --release
