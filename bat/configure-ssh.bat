@echo off
setlocal EnableDelayedExpansion

@REM Get user input

echo This tool streamlines the one-time setup process for using this machine as an SSH client to connect to a specific SSH server
echo.
echo Please enter the details of the server you would like to configure a connection to:

echo.
echo ip address or hostname:
set /p ip=">"
echo port [22]:
set /p port=">"
echo username [%USERNAME%]:
set /p user=">"

echo.

if "!ip!"=="" (
    echo Invalid address/hostname
    exit /b
)

if "!port!"=="" set port=22
if "!user!"=="" set user=%USERNAME%

@REM Ensure SSH key pair

set ssh_dir=%userprofile%\.ssh
set pubkey="%ssh_dir%\id_ed25519.pub"
set privkey="%ssh_dir%\id_ed25519"

if not exist "%privkey%" (
    echo Generating new SSH key...
    ssh-keygen -t ed25519 -f "%privkey%" -N ""
    if !errorlevel! neq 0 (
        echo Failed to generate private key.
        pause
        exit /b
    )
)

if not exist "%pubkey%" (
    echo Key public does not exist, generating now...
    ssh-keygen -y -f "%privkey%" > "%pubkey%"
    if !errorlevel! neq 0 (
        echo Failed to generate public key.
        pause
        exit /b
    )
)

set ssh=ssh -i "%privkey%" -o BatchMode=yes -o StrictHostKeyChecking=no -p !port! !user!@!ip!

%ssh% "echo SSH key already configured." 2>NUL
if !errorlevel! neq 0 (
    echo Copying SSH key...
    type "!pubkey!" | ssh -o StrictHostKeyChecking=no -p !port! !user!@!ip! "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
    if !errorlevel! neq 0 (
        echo Failed to copy the public key to the SSH server.
        pause
        exit /b
    ) else (
        %ssh% "echo SSH key successfully installed." 2>NUL
    )
)

@REM Update local ssh config file

set config="!ssh_dir!\config"
set "host_entry=Host !ip!-!user!"
set entry_exists="false"

for /f "tokens=*" %%i in ('type "!config!" ^| findstr /C:"!host_entry!"') do (
    set entry_exists="true"
)

if !entry_exists! == "true" (
    echo Updating '!config!' entry...
    set "in_entry=false"
    > "!config!.tmp" (
        for /f "delims=" %%a in ('type "!config!"') do (
            set "line=%%a"
            set "trimmed_line=!line: =!"
            if "!line!"=="!host_entry!" (
                echo !host_entry!
                echo     HostName !ip!
                echo     Port !port!
                echo     User !user!
                echo     AddKeysToAgent yes
                echo     IdentityFile !privkey!
                set "in_entry=true"
            ) else (
                if "!in_entry!"=="true" (
                    if "!line:~0,1!"==" " (
                        REM Skip the line because it's part of the previous entry.
                    ) else (
                        set "in_entry=false"
                        if not defined trimmed_line (
                            echo.
                        ) else (
                            echo !line!
                        )
                    )
                ) else (
                    if not defined trimmed_line (
                        echo.
                    ) else (
                        echo !line!
                    )
                )
            )
        )
    )
    move /Y "!config!.tmp" "!config!" > NUL
    echo Entry updated successfully
) else (
    echo Adding entry to '!config!'...
    echo. >> "!config!"
    >> "!config!" (
        echo !host_entry!
        echo     HostName !ip!
        echo     Port !port!
        echo     User !user!
        echo     AddKeysToAgent yes
        echo     IdentityFile !privkey!
    )
    echo Entry added successfully
)

%ssh% "echo hi > /dev/null"
if !errorlevel! neq 0 (
    echo Failed to connect using SSH key after installing
    pause
    exit /b
)

@REM Handle disabling of clear-text passwords

%ssh% "grep -E 'PasswordAuthentication' /etc/ssh/sshd_config | grep -v '^#' | grep 'no' > /dev/null"

if !errorlevel! neq 0 (
    echo Now that key-based SSH auth is configured, it is recommended to disable password-based auth for security reasons. Would you like to do this now? [Y/n]
    set /p disable_password_auth=">"
    if /i "!disable_password_auth!" NEQ "n" (
        echo Disabling password-based authentication...
        %ssh% "sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config && sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config && sudo systemctl restart ssh"
        if !errorlevel! neq 0 (
            echo Failed to disable password authentication.
        ) else (
            echo Password-based authentication disabled successfully.
        )
    ) else (
        echo Leaving clear-text password authentication enabled.
    )
) else (
    echo Password-based authentication already disabled.
)

echo.
echo SSH configuration complete. Connect using the following command:
if !port! == 22 (
    echo    ssh !user!@!ip!
) else (
    echo    ssh !user!@!ip! -p !port!
)
echo.

pause
exit /b
