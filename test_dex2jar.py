import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('195.226.92.151', username='root', password='chEdZThrFb8v7', timeout=15)
_, stdout, _ = c.exec_command('''
wget -q https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-2.4.zip
unzip -q dex-tools-2.4.zip
chmod +x dex-tools-2.4/*.sh
wget -qO sfa.apk https://github.com/SagerNet/sing-box/releases/download/v1.11.7/SFA-1.11.7-universal.apk
./dex-tools-2.4/d2j-dex2jar.sh sfa.apk -o full.jar
unzip -l full.jar | grep BoxService
''')
print(stdout.read().decode())
c.close()
