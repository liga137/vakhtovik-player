import urllib.request
import zipfile
import os

url = "https://github.com/SagerNet/sing-box/releases/download/v1.13.13/SFA-1.13.13-arm64-v8a.apk"
apk_path = "sfa_test.apk"

print("Downloading...")
urllib.request.urlretrieve(url, apk_path)
print("Downloaded")

with zipfile.ZipFile(apk_path, 'r') as z:
    z.extract('classes.dex', '.')
    print("Extracted classes.dex")
