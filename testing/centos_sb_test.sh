#!/bin/bash

# This script accepts multiple paramaters
# see usage() for required parameters

# To get the Name and the KEYID for the latest secureboot crt, look in one of
# the secureboot signed packages (currently centossecureboot201.crt) and use the command:
# openssl x509 -in centossecureboot201.crt -text
# You want to build "--expect-cert" from the Issuer: CN (line 8) and the X509v3 Authority Key Identifier (line 46).  Remove the : and convert to lower case.
# example:  echo 5D:4B:64:F2:FA:63:1E:5E:5F:DB:AA:DC:14:67:C6:6C:99:21:7A:22 | sed | 's,:,,g' | awk '{print tolower($0)}'

function usage() {
cat << EOF

You need to call the script like this: $0 -arguments
-k : kernel RPM pkg to test (url)
-s : shim RPM pkg to test (url)
-g : grub2 RPM pkg to test (url)
-h : display this help
EOF
}

function varcheck() {
if [ -z "$1" ] ; then
        usage
        exit 1
fi
}

# Some defined variables
# need a specific OVMF that has the MS keys rolled-in
# This is usually the latest OVMF from the mirrors, could come from QA repos if testing new release
ovmf_rpm="http://mirror.centos.org/centos/7/os/x86_64/Packages/OVMF-20180508-6.gitee3198e672e2.el7.noarch.rpm"

while getopts "hk:s:g:" option
do
  case ${option} in
    h)
      usage
      exit 1
      ;;
    s)
      shim_rpm=${OPTARG}
      ;;
    k)
      kernel_rpm=${OPTARG}
      ;;
    g)
      grub2_rpm=${OPTARG}
      ;;
    ?)
      usage
      exit
      ;;
  esac
done

varcheck ${shim_rpm}
varcheck ${kernel_rpm}
varcheck ${grub2_rpm}

echo "==== Validating SecureBoot with following pkgs ===="
echo ""
echo "  SHIM : $shim_rpm"
echo "  Grub2 : $grub2_rpm"
echo "  kernel : $kernel_rpm"
echo "  OVMF : $ovmf_rpm"
echo ""
echo "==================================================="


workdir=$(mktemp -d -p /var/tmp)

pushd $workdir
for pkg_url in $shim_rpm $kernel_rpm $grub2_rpm $ovmf_rpm; do
  echo "### Downloading $pkg_url in $workdir ..."
  curl --location --fail --silent -O $pkg_url
  if [ "$?" -ne "0" ] ;then
    echo "Download for $pkg_url FAILED"
    exit 1
  fi
  pkg_file=$(echo $pkg_url|rev|cut -f 1 -d '/'|rev)
  echo "### Extracting file from $pkg_file"
  rpm2cpio $pkg_file|cpio -idm

done
popd

kernel_file=$(find $workdir -name 'vmlinuz*')
shim_file=$(find $workdir -name 'shimx64.efi')
grub2_file=$(find $workdir -name 'grubx64.efi')


# Installing required pkgs
echo "[+] Installing now required yum packages ..."
yum install -d0 centos-release-qemu-ev -y
yum install -d0 qemu-kvm-tools qemu-kvm virt-install libvirt libvirt-python -y
yum install -y -d0 git pesign dosfstools
yum localinstall -d0 -y ${workdir}/OVMF*


if [ ! -d qemu-secureboot-tester ];
then
    git clone https://github.com/puiterwijk/qemu-secureboot-tester.git
fi

# Validating if we need to sign shim or if it's already signed by Microsoft
rpm -qip $workdir/shim*|grep -q unsigned && shim_is_signed=False || shim_is_signed=True


echo " Test [1/1] : Validating that we can boot the whole chain : shim, grub2, kernel"

staging_dir=$(mktemp -d -p /var/tmp)
if [ "$shim_is_signed" == "True" ] ; then
  echo "$shim_file is supposed to be signed, so testing about Microsoft MOK ..."
python qemu-secureboot-tester/sbtest \
  --qemu-binary /usr/libexec/qemu-kvm \
  --verbose \
  --print-output \
  --enable-kvm \
  --test-signed \
  --ovmf-binary /usr/share/OVMF/OVMF_CODE.secboot.fd \
  --ovmf-template-vars /usr/share/OVMF/OVMF_VARS.secboot.fd \
  --expect-cert "CentOS Secure Boot CA 2: 70007f99209c126be14774eaec7b6d9631f34dca" \
   $shim_file $grub2_file $kernel_file
else
   echo "$shim_file is supposed to be unsigned, so auto-signing it to validate other pkgs ..."
python qemu-secureboot-tester/sbtest \
  --qemu-binary /usr/libexec/qemu-kvm \
  --verbose \
  --print-output \
  --enable-kvm \
  --ovmf-binary /usr/share/OVMF/OVMF_CODE.secboot.fd \
  --ovmf-template-vars /usr/share/OVMF/OVMF_VARS.fd \
  --expect-cert "CentOS Secure Boot CA 2: 70007f99209c126be14774eaec7b6d9631f34dca" \
   $shim_file $grub2_file $kernel_file
fi


if [ "$?" -eq "0" ] ;then
  echo ""
  echo "[+] SecureBoot tested worked : SUCCESS"
  exit 0
elif [ "$?" -eq "1" ]; then
  echo ""
  echo "[+] SecureBoot test error : setup error = > FAIL"
  exit 1

elif [ "$?" -eq "2" ]; then
  echo ""
  echo "[+] SecureBoot test error : SHIM error => FAIL"
  exit 1

elif [ "$?" -eq "3" ]; then
  echo ""
  echo "[+] SecureBoot test error : GRUB error => FAIL"
  exit 1

elif [ "$?" -eq "4" ]; then
  echo ""
  echo "[+] SecureBoot test error : Kernel error => FAIL"
  exit 1

fi
