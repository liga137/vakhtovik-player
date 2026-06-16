import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('195.226.92.151', username='root', password='chEdZThrFb8v7', timeout=15)
_, stdout, _ = c.exec_command('wget -qO sfa.apk https://github.com/SagerNet/sing-box/releases/download/v1.13.13/SFA-1.13.13-arm64-v8a.apk && unzip -o sfa.apk classes.dex && strings classes.dex | grep -i "BoxService"')
print(stdout.read().decode())
c.close()
