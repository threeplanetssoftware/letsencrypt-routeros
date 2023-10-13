#!/bin/bash

while getopts 'u:h:p:k:d:c:' OPTION; do
	case "$OPTION" in
	u)
		ROUTEROS_USER=$OPTARG
		;;
	h)
		ROUTEROS_HOST=$OPTARG
		;;
	p)
		ROUTEROS_SSH_PORT=$OPTARG
		;;
	k)
		ROUTEROS_PRIVATE_KEY=$OPTARG
		;;
	d)
		DOMAIN=$OPTARG
		;;
	c)
		CONFIG=$OPTARG
		;;
	*)
		echo "Unknown option '$OPTION'"
		;;
	esac
done
shift "$((OPTIND - 1))"

if [[ -n $CONFIG ]]; then
	source "$CONFIG"
elif [[ -z $ROUTEROS_USER ]] || [[ -z $ROUTEROS_HOST ]] || [[ -z $ROUTEROS_SSH_PORT ]] || [[ -z $ROUTEROS_PRIVATE_KEY ]] || [[ -z $DOMAIN ]]; then
	echo -e "Usage:\n$0 -c /path/to/config\nOR\n$0 -u [RouterOS User] -h [RouterOS Host] -p [SSH Port] -k [SSH Private Key] -d [Domain]"
	exit 1
fi

if [[ -z $ROUTEROS_USER ]] || [[ -z $ROUTEROS_HOST ]] || [[ -z $ROUTEROS_SSH_PORT ]] || [[ -z $ROUTEROS_PRIVATE_KEY ]] || [[ -z $DOMAIN ]]; then
	echo "Check the config file $CONFIG_FILE or start with params: $0 -u [RouterOS User] -h [RouterOS Host] -p [SSH Port] -k [SSH Private Key] -d [Domain]"
	echo "Please avoid spaces"
	exit 1
fi

CERTIFICATE=/etc/letsencrypt/live/${DOMAIN}/cert.pem
KEY=/etc/letsencrypt/live/${DOMAIN}/privkey.pem

echo ""
echo "Updating certificate for $DOMAIN"
echo "  Using certificate $CERTIFICATE"
echo "  User private key $KEY"

#Create alias for RouterOS command
routeros="ssh -o PubkeyAcceptedKeyTypes=+ssh-dss -o StrictHostKeyChecking=${SSH_STRICT_KEY_CHECKING:-yes} -i $ROUTEROS_PRIVATE_KEY ${ROUTEROS_USER}@${ROUTEROS_HOST} -p $ROUTEROS_SSH_PORT"

#Create alias for scp command
scp="scp -q -o PubkeyAcceptedKeyTypes=+ssh-dss -o StrictHostKeyChecking=${SSH_STRICT_KEY_CHECKING:-yes} -P $ROUTEROS_SSH_PORT -i $ROUTEROS_PRIVATE_KEY"

echo ""
echo "Checking connection to RouterOS"

#Check connection to RouterOS
$routeros /system resource print
RESULT=$?

if [[ ! ${RESULT} == 0 ]]; then
	echo -e "\nError in: $routeros"
	echo "More info: https://wiki.mikrotik.com/wiki/Use_SSH_to_execute_commands_(DSA_key_login)"
	exit 1
else
	echo -e "\nConnection to RouterOS Successful!\n"
fi

if [ ! -f "$CERTIFICATE" ] && [ ! -f "$KEY" ]; then
	echo -e "\nFile(s) not found:\n${CERTIFICATE}\n${KEY}\n"
	echo -e "Please use CertBot Let'sEncrypt:"
	echo "============================"
	echo "certbot certonly --preferred-challenges=dns --manual -d $DOMAIN --manual-public-ip-logging-ok"
	echo "or (for wildcard certificate):"
	echo "certbot certonly --preferred-challenges=dns --manual -d *.$DOMAIN --manual-public-ip-logging-ok --server https://acme-v02.api.letsencrypt.org/directory"
	echo "==========================="
	echo -e "and follow instructions from CertBot\n"
	exit 1
fi

# Set up variables to remove errors
DOMAIN_INSTALLED_CERT_FILE=${DOMAIN}.pem_0
DOMAIN_CERT_FILE=${DOMAIN}.pem
DOMAIN_KEY_FILE=${DOMAIN}.key

# Remove previous certificate
echo "Removing old certificate from installed certificates: $DOMAIN_INSTALLED_CERT_FILE"
$routeros /certificate remove [find name="$DOMAIN_INSTALLED_CERT_FILE"]

echo ""
echo "Handling new certificate file"
# Create Certificate
# Delete Certificate file if the file exist on RouterOS
echo "  Deleting any old copy of certificate file from disk: $DOMAIN_CERT_FILE"
$routeros /file remove "$DOMAIN_CERT_FILE" >/dev/null
# Upload Certificate to RouterOS
echo "  Uploading new domain certificate file to router: $CERTIFICATE"
$scp "$CERTIFICATE" "$ROUTEROS_USER"@"$ROUTEROS_HOST":"$DOMAIN_CERT_FILE"
sleep 2
# Import Certificate file
echo "  Importing new certificate file to router certificates"
$routeros /certificate import file-name="$DOMAIN_CERT_FILE" passphrase=\"\"
# Delete Certificate file after import
echo "  Deleting any new copy of certificate file from disk: $DOMAIN_CERT_FILE"
$routeros /file remove "$DOMAIN_CERT_FILE"

echo ""
echo "Handling new key file"
# Create Key
# Delete Certificate file if the file exist on RouterOS
echo "  Deleting any old copy of key file from disk: ${DOMAIN_KEY_FILE}"
$routeros /file remove "$DOMAIN_KEY_FILE" >/dev/null
# Upload Key to RouterOS
echo "  Uploading new domain key file to router: $KEY"
$scp "$KEY" "$ROUTEROS_USER"@"$ROUTEROS_HOST":"$DOMAIN_KEY_FILE"
sleep 2
# Import Key file
echo "  Importing new key file to router certificates"
$routeros /certificate import file-name="$DOMAIN_KEY_FILE" passphrase=\"\"
# Delete Certificate file after import
echo "  Deleting any new copy of key file from disk: $DOMAIN_KEY_FILE"
$routeros /file remove "$DOMAIN_KEY_FILE"

echo ""

# Setup Certificate to SSTP Service
if [[ "${SETUP_SERVICES[*]:-SSTP}" =~ "SSTP" ]]; then
	echo "Updating SSTP Server to use $DOMAIN_INSTALLED_CERT_FILE"
	$routeros /interface sstp-server server set certificate="$DOMAIN_INSTALLED_CERT_FILE"
fi

# Setup Certificate to WWW Service
if [[ "${SETUP_SERVICES[*]:-WWW}" =~ "WWW" ]]; then
	echo "Updating HTTPS Server to use $DOMAIN_INSTALLED_CERT_FILE"
	$routeros /ip service set www-ssl certificate="$DOMAIN_INSTALLED_CERT_FILE"
fi

# Setup Certificat to API Service
if [[ "${SETUP_SERVICES[*]:-API}" =~ "API" ]]; then
	echo "Updating API SSL Server to use $DOMAIN_INSTALLED_CERT_FILE"
	$routeros /ip service set api-ssl certificate="$DOMAIN_INSTALLED_CERT_FILE"
fi

exit 0
