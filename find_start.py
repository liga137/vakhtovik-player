import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('195.226.92.151', username='root', password='chEdZThrFb8v7', timeout=15)
_, stdout, _ = c.exec_command('nm -D lib/arm64-v8a/libbox.so | grep Java_io_nekohasekai_libbox | grep -iE "box|start|run|setup"')
print(stdout.read().decode())
c.close()
