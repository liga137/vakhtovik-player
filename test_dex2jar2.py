import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('195.226.92.151', username='root', password='chEdZThrFb8v7', timeout=15)
_, stdout, stderr = c.exec_command('''
./dex-tools-2.4/d2j-dex2jar.sh sfa.apk -o full.jar 2>&1
unzip -l full.jar | grep BoxService
''')
print("OUT:", stdout.read().decode())
print("ERR:", stderr.read().decode())
c.close()
