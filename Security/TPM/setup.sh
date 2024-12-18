#!/bin/bash
# Full disk encryption on Linux using a LUKS key stored in a TPM2 device
#
# Use at your own risk!  I have tried to make this safe and generalized, but
# I make no guarantees it will work or be safe on your system, and take no
# responsibility for any damages or losses incurred from this.
#
# Based on the excellent work by etzion at
# https://run.tournament.org.il/ubuntu-18-04-and-tpm2-encrypted-system-disk/
# https://run.tournament.org.il/ubuntu-20-04-and-tpm2-encrypted-system-disk/
#
# This script alone is not enough to protect your system!  At a minimum, you
# should also set a BIOS password and disable USB booting.  See etzion's
# comment here for further details:
# https://run.tournament.org.il/ubuntu-20-04-and-tpm2-encrypted-system-disk/#comment-501794
#
# Version: 2.0.0

KEYSIZE=64

# Check if running as root
if (( $EUID != 0 )); then
    echo "This script must run with root privileges, e.g.:"
    echo "sudo $0 $1"
    exit
fi

#Get user confirmation
echo "This script will generate a random alphanumeric key, store it in your TPM2 device,"
echo "then add it as a LUKS key to an encrypted drive.  It will then create scripts"
echo "necessary for unlocking the drive automatically at boot by reading the key from"
echo "the TPM2 device, and update initramfs to include the scripts."
echo
while true
do
   read -p "Do you want to proceed? (yes/NO) " PROMPT
   if [ "${PROMPT,,}" == "yes" ] || [ "${PROMPT,,}" == "y" ]
   then
      break
   elif [ "${PROMPT,,}" == "no" ] || [ "${PROMPT,,}" == "n" ] || [ "${PROMPT,,}" == "" ]
   then
      echo "Cancelling, no changes have been made to the system."
      exit
   fi
   echo "Sorry, I didn't understand that. Please type yes or no"
done

#Clear out anything stored in variables we use
unset CRYPTTAB_DEVICE_NAMES
unset CRYPTTAB_DEVICE_PATHS
unset CRYPTTAB_DEVICE_SELECTED

if ! dpkg -s cryptsetup-bin 1> /dev/null 2> /dev/null
then
   echo
   echo "cryptsetup-bin not detected, installing..."
   apt install cryptsetup-bin -y
fi

if ! dpkg -s initramfs-tools-core 1> /dev/null 2> /dev/null
then
   echo
   echo "initramfs-tools-core not detected, installing..."
   apt install initramfs-tools-core -y
fi

if ! dpkg -s tpm2-tools 1> /dev/null 2> /dev/null
then
   echo
   echo "tpm2-tools not detected, installing..."
   apt install tpm2-tools -y
fi

# Attempt to read from the TPM2 to see if something is already there
KEY=$(tpm2_nvread 0x1500016 2> /dev/null)
if [ "$KEY" != "" ]
then # found something is already there
   echo
   echo "Looks like there is already a key stored in the TPM2 device."
   echo "Using the existing key will ensure any other devices depending on it will still"
   echo "automatically unlock at boot."
   echo
   echo "If you choose NOT to use the existing key, a new key will be generated which will"
   echo "overwrite the existing key so any devices using the old key will need to be"
   echo "manually unlocked at boot if don't select time select them this time.  The existing"
   echo "key will NOT be removed from any devices using it and can still be used manually."
   while true
   do
      read -p "Do you want to use the existing key? (YES/no) " PROMPT
      if [ "${PROMPT,,}" == "yes" ] || [ "${PROMPT,,}" == "y" ] || [ "${PROMPT,,}" == "" ]
      then
         echo
         echo "Ok, reusing the key..."

         # Store the key in /root/tpm2.key
         echo -n $KEY > /root/tpm2.key
         KEYSIZE=${#KEY}

         break
      elif [ "${PROMPT,,}" == "no" ] || [ "${PROMPT,,}" == "n" ]
      then
         KEY=""
         break
      fi
      echo "Sorry, I didn't understand that. Please type yes or no"
   done
fi

#Add encrypted drives listed in /etc/crypttab to an array, quit if none found
#grep explanation:
# -o returns only matching portion
# regex: ^ matches the beginning of the line, \s* matches zero or more whitespace
# [^#[:space:]] matches a character that is NOT either '#' (to exclude commented lines) or more
# whitespace.  PCRE supports \s inside a character class, but grep basic and extended regex
# engines don't, so I opted for what I believe will be the most compatible route and used [:space:]
# \S+ matches one or more non-whitespace characters, in this case the rest of the first word
TEMP_DEVICE_NAMES=($(grep -o '^\s*[^#[:space:]]\S*' /etc/crypttab))
if [ ${#TEMP_DEVICE_NAMES[@]} = 0 ]
then
   echo "Could not find any encrypted drives in /etc/crypttab."
   echo "Your drive must already be encrypted before running this script."
   exit
fi
#Build parallel arrays consisting of associated device names and paths
for (( I = 0; I < ${#TEMP_DEVICE_NAMES[@]}; I++))
do
   #Get the device name from cryptsetup
   #sed explanation:
   # -n supresses printing by default, -E uses extended regex engine
   # s to search, '/' are search parameter delimeters.  Look for "device:" followed by at least
   # one whitespace character, then get the rest of the line.  Replace the whole match with what
   # was in parentheses (the device path in this case).  Final "p" parameter tells it to print that line
   TEMP_DEVICE_PATH=$(cryptsetup status ${TEMP_DEVICE_NAMES[$I]} | sed -n -E 's/device:\s+(.*)/\1/p')
   if [ "$TEMP_DEVICE_PATH" != "" ] && $(cryptsetup isLuks $TEMP_DEVICE_PATH 2> /dev/null)
   then
      #Device has a name, a path, and is a valid LUKS device
      CRYPTTAB_DEVICE_NAMES+=( ${TEMP_DEVICE_NAMES[$I]} )
      CRYPTTAB_DEVICE_PATHS+=( $TEMP_DEVICE_PATH )
      CRYPTTAB_DEVICE_SELECTED+=( "n" )
   fi
done

#Ask user which target they want to run the script against
SELECTIONS_COMPLETE="no"
while [ "$SELECTIONS_COMPLETE" == "no" ]
do
   echo
   echo
   echo "Devices found in crypttab:"
   for I in "${!CRYPTTAB_DEVICE_NAMES[@]}"
   do
      echo "Selected: ${CRYPTTAB_DEVICE_SELECTED[$I]}	Index: $I	Path: ${CRYPTTAB_DEVICE_PATHS[$I]}	Name: ${CRYPTTAB_DEVICE_NAMES[$I]} $(grep -q "^\s*${CRYPTTAB_DEVICE_NAMES[$I]}.*tpm2-getkey" /etc/crypttab && echo " (already setup to automatically unlock at boot)")"
   done  #for I loop
   echo
   echo "Enter the index numbers of devices separated by spaces to select/unselect them"
   echo "Enter 'a' to select all devices, 'n' to unselect all devices, or 'd' when done:"
   read PROMPT

   REGEX='^[0-9]+$'
   for I in $PROMPT
   do
      if [ "$I" = "a" ]
      then
         for J in "${!CRYPTTAB_DEVICE_SELECTED[@]}"
         do
            CRYPTTAB_DEVICE_SELECTED[$J]="y"
         done  #for J loop
      elif [ "$I" = "n" ]
      then
         for J in "${!CRYPTTAB_DEVICE_SELECTED[@]}"
         do
            CRYPTTAB_DEVICE_SELECTED[$J]="n"
         done  #for J loop
      elif [ "$I" = "d" ]
      then
         SELECTIONS_COMPLETE="yes"
         break  #for I loop
      elif [[ $I =~ $REGEX ]] && (( $I < ${#CRYPTTAB_DEVICE_SELECTED[@]} )) # $I is a positive integer and is in the range of devices
      then
         if [ "${CRYPTTAB_DEVICE_SELECTED[$I]}" = "n" ]
         then
            CRYPTTAB_DEVICE_SELECTED[$I]="y"
         else
            CRYPTTAB_DEVICE_SELECTED[$I]="n"
         fi
      fi
   done  #for I loop
done  #while loop

# Check to make sure at least one device has been selected
echo ${CRYPTTAB_DEVICE_SELECTED[@]} | grep -q "y"
if [ $? != 0 ]
then
   echo
   echo "No drives were selected.  Cancelling, no changes have been made to the system."
   exit
fi

if [ "$KEY" == "" ] # No key was found in TPM2 or user wants a new key made
then
   # Generate a $KEYSIZE long char alphanumeric key and save it to /root/tpm2.key
   KEY=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c $KEYSIZE)

   # Store the key in /root/tpm2.key
   echo -n $KEY > /root/tpm2.key

   # Clear out the area on the TPM2 just to be safe
   tpm2_nvundefine 0x1500016 2> /dev/null

   # Define the area for the key on the TPM2
   tpm2_nvdefine -s $KEYSIZE 0x1500016 > /dev/null

   # Store the key in the TPM
   tpm2_nvwrite -i /root/tpm2.key 0x1500016

   # Make sure /root/tpm2.key and the TPM2 device match
   tpm2_nvread -s $KEYSIZE 0x1500016 2> /dev/null | diff /root/tpm2.key - > /dev/null
   if [ $? != 0 ]
   then
      echo "Could not verify the key is stored properly in the TPM2 device."
      echo "Cannot proceed!"
      exit
   fi
fi

# Iterate over all selected devices, using the same key for them all
echo
echo
echo
echo "You will need to unlock each selected device to add the new key."
for I in "${!CRYPTTAB_DEVICE_NAMES[@]}"
do
   if [ "${CRYPTTAB_DEVICE_SELECTED[$I]}" = "y" ]
   then
      echo
      echo "Adding key to ${CRYPTTAB_DEVICE_NAMES[$I]} (${CRYPTTAB_DEVICE_PATHS[$I]})..."
      cryptsetup luksAddKey ${CRYPTTAB_DEVICE_PATHS[$I]} /root/tpm2.key
      if [ $? != 0 ]
      then
         echo
         echo "Something went wrong adding the key, possibly the wrong passphrase was used."
         while true
         do
            read -p "Try entering the passphase again? (YES/no) " PROMPT
            if [ "${PROMPT,,}" == "yes" ] || [ "${PROMPT,,}" == "y" ] || [ "${PROMPT,,}" == "" ]
            then
               echo
               echo "Adding key to ${CRYPTTAB_DEVICE_NAMES[$I]} (${CRYPTTAB_DEVICE_PATHS[$I]})..."
               cryptsetup luksAddKey ${CRYPTTAB_DEVICE_PATHS[$I]} /root/tpm2.key
               if [ $? == 0 ]
               then
                  break # while loop
               fi
            elif [ "${PROMPT,,}" == "no" ] || [ "${PROMPT,,}" == "n" ]
            then
               echo
               echo "Couldn't add the new key to ${CRYPTTAB_DEVICE_NAMES[$I]} (${CRYPTTAB_DEVICE_PATHS[$I]}), quitting."
               echo "No changes have been made to the boot environment."
               exit
            else
               echo "Sorry, I didn't understand that. Please type yes or no"
            fi
         done # while loop
      fi
   fi
done # for loop

# Removing /root/tpm2.key file for extra security
rm /root/tpm2.key

# Creating a key recovery script and putting it at /usr/local/sbin/tpm2-getkey...
cat << EOF > /usr/local/sbin/tpm2-getkey
#!/bin/sh
if [ "\${CRYPTTAB_NAME}" != "" ]
then
   TMP_FILE=".tpm2-getkey.\${CRYPTTAB_NAME}.tmp"

   if [ -f "\${TMP_FILE}" ]
   then
      # tmp file exists, meaning we tried the TPM2 this boot, but it didn’t work for the drive and this must be the second
      # or later try to unlock the drive. Either the TPM2 is failed/missing, or has the wrong key stored in it.
      /lib/cryptsetup/askpass "Automatic disk unlock via tpm2-getkey failed for (\${CRYPTTAB_SOURCE}) Enter passphrase: "
      exit
   fi

   # No tmp, so it is the first time trying the script. Create a tmp file and try the TPM
   touch \${TMP_FILE}
   tpm2_nvread -s ${KEYSIZE} 0x1500016
else
   echo \$(tpm2_nvread -s ${KEYSIZE} 0x1500016)
fi

EOF

# Set the file ownership and permissions
chown root: /usr/local/sbin/tpm2-getkey
chmod 750 /usr/local/sbin/tpm2-getkey

# Creating initramfs hook and putting it at /etc/initramfs-tools/hooks/tpm2-decryptkey
cat << EOF > /etc/initramfs-tools/hooks/tpm2-decryptkey
#!/bin/sh
PREREQ=""
prereqs()
 {
     echo "\${PREREQ}"
 }
case \$1 in
 prereqs)
     prereqs
     exit 0
     ;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec \$(which tpm2_nvread)
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0.0.0
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0
exit 0
EOF

# Set the file ownership and permissions

chown root: /etc/initramfs-tools/hooks/tpm2-decryptkey
chmod 755 /etc/initramfs-tools/hooks/tpm2-decryptkey

echo
echo
echo
echo "Backing up /etc/crypttab to /etc/crypttab.bak then updating"
echo "selected devices to unlock automatically..."
cp /etc/crypttab /etc/crypttab.bak
# Iterate over all selected devices, adding keyscript as needed
for I in "${!CRYPTTAB_DEVICE_NAMES[@]}"
do
   # Only process selected devices
   if [ "${CRYPTTAB_DEVICE_SELECTED[$I]}" = "y" ]
   then
      # Check to see if tpm2-getkey has already been added to the device manually or by a previous version
      grep -q "^\s*${CRYPTTAB_DEVICE_NAMES[$I]}.*tpm2-getkey" /etc/crypttab
      if [ $? != 0 ]
      then
        # grep did not find the keyscript on the line for the device, need to add it.
        # the initramfs parameter is also added so it will be unlocked before systemd
        # because systemd does not directly support keyscripts so secondary drives
        # won't unlock.  Eventually would be good to switch to using an AF_UNIX socket
        # backed by a systemd service that calls the keyscript.  Jumping off point here:
        # https://github.com/systemd/systemd/pull/3007
		# sed explanation:
		# using " instead of ' because of the variable, using % as the sed delimiter to avoid needing to
		# escape / characters.  The ( and ) characters are escaped so I can reference the contents on the
		# replace side.  ^ starts at the beginning of the line, \s* looks for any amount of whitespace,
		# then it looks for the device name and the whole rest of the line.  The replacement is the
		# just the whole line, plus a comma and the keyscript parameter.  Note this stops after the first
		# match, but that should be fine.  It won't match commented lines, and there should never be duplicate
		# devices listed in /etc/crypttab
        sed -i "s%\(^\s*${CRYPTTAB_DEVICE_NAMES[$I]}.*\)$%\1,initramfs,keyscript=/usr/local/sbin/tpm2-getkey%" /etc/crypttab
      fi
   fi
done # for I loop

# e.g. this line: sda3_crypt UUID=d4a5a9a4-a2da-4c2e-a24c-1c1f764a66d2 none luks
# should become : sda3_crypt UUID=d4a5a9a4-a2da-4c2e-a24c-1c1f764a66d2 none luks,initramfs,keyscript=/usr/local/sbin/tpm2-getkey

if ! [ -f "/boot/initrd.img-$(uname -r).orig" ]
then
   # Backup up initramfs to /boot/initrd.img-$(uname -r).orig
   cp /boot/initrd.img-$(uname -r) /boot/initrd.img-$(uname -r).orig
fi

#Update initramfs to support automatic unlocking from the TPM2
mkinitramfs -o /boot/initrd.img-$(uname -r) $(uname -r)

echo
echo
echo
echo "Before you reboot and try it out, please note the following:"
echo "If the drive unlocks as expected, you may optionally remove the original password"
echo "used to encrypt the drive and rely completely on the random new one stored in the"
echo "TPM2.  If you do this, you should keep a copy of the key somewhere outside this"
echo "system. E.g. printed and kept locked somewhere safe. To get a copy of the key"
echo "stored in the TPM2, run this command:"
echo
echo "sudo tpm2-getkey"
echo
echo "If you remove the original password used to encrypt the drive and don't have a"
echo "backup copy of the TPM2's key and then experience TPM2, motherboard, or some"
echo "other failure preventing automatic unlock, you WILL LOSE ACCESS TO EVERYTHING ON"
echo "THE ENCRYPTED DRIVE(S)!"
echo
echo "If you are SURE you have a backup of the key you put in the TPM2, and you REALLY"
echo "want to remove the old password here are the commands for each drive.  This is NOT RECOMMENDED"
echo
# Iterate over all selected devices
for I in "${!CRYPTTAB_DEVICE_NAMES[@]}"
do
   # Only process selected devices
   if [ "${CRYPTTAB_DEVICE_SELECTED[$I]}" = "y" ]
   then
      echo "sudo cryptsetup luksRemoveKey ${CRYPTTAB_DEVICE_NAMES[$I]}"
   fi
done # for I loop
echo
echo "If booting fails, press esc at the beginning of the boot to get to the grub menu."
echo "Edit the Ubuntu entry and add .orig to end of the initrd line to boot to the"
echo "original initramfs for recovery. e.g.:"
echo
echo "initrd /initrd.img-$(uname -r).orig"
echo