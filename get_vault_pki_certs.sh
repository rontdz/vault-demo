#!/bin/bash

# Function to display usage
usage() {
  echo "Usage: $0 -a VAULT_ADDR -t VAULT_TOKEN -d DAYS"
  echo "  -a VAULT_ADDR   Vault server address"
  echo "  -t VAULT_TOKEN  Vault authentication token"
  echo "  -d DAYS         Number of days from today within which certificates should expire"
  exit 1
}

# Parse command-line arguments
while getopts "a:t:d:" opt; do
  case $opt in
    a) VAULT_ADDR=$OPTARG ;;
    t) VAULT_TOKEN=$OPTARG ;;
    d) DAYS=$OPTARG ;;
    *) usage ;;
  esac
done

# Check if all parameters are provided
if [ -z "$VAULT_ADDR" ] || [ -z "$VAULT_TOKEN" ] || [ -z "$DAYS" ]; then
  usage
fi

# Output CSV file
OUTPUT_CSV="certificates.csv"

# Function to get a list of certificate IDs
get_certificate_ids() {
  curl -s \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request LIST \
    $VAULT_ADDR/v1/pki/certs
}

# Function to get certificate
get_certificate() {
  local cert_id=$1
  curl -s \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    $VAULT_ADDR/v1/pki/cert/$cert_id | jq -r '.data.certificate'
}

# Function to extract certificate details using openssl
extract_certificate_details() {
  local cert_data=$1
  local cert_id=$2

  # Save certificate to a temporary file
  local cert_file=$(mktemp)
  echo "$cert_data" > $cert_file

  # Extract common name
  local common_name=$(openssl x509 -in $cert_file -noout -subject | sed -n 's/.*CN=\([^,]*\).*/\1/p')

  # Extract expiry date
  local expiry_date=$(openssl x509 -in $cert_file -noout -enddate | sed 's/notAfter=//')

  # Convert expiry date to YYYY-MM-DD format
  local expiry_date_formatted=$(date -d "$expiry_date" +%Y-%m-%d 2>/dev/null || python3 -c "import datetime; print((datetime.datetime.strptime('$expiry_date', '%b %d %H:%M:%S %Y %Z')).strftime('%Y-%m-%d'))")

  # Clean up temporary file
  rm -f $cert_file

  # Return extracted details
  echo "$cert_id,$common_name,$expiry_date_formatted"
}

# Function to calculate the cutoff date
calculate_cutoff_date() {
  python3 -c "import datetime; print((datetime.datetime.now() + datetime.timedelta(days=$DAYS)).strftime('%Y-%m-%d'))"
}

# Main script
echo "Fetching certificate details from Vault PKI..."

# Get all certificate IDs
cert_ids_response=$(get_certificate_ids)
echo "Certificate IDs response: $cert_ids_response"

# Extract certificate IDs
cert_ids=$(echo "$cert_ids_response" | jq -r '.data.keys[]')

# Check if there are any certificates
if [ -z "$cert_ids" ]; then
  echo "No certificates found."
  exit 0
fi

# Prepare the CSV file with headers
echo "ID,Common Name,Expiry Date" > $OUTPUT_CSV

# Calculate the cutoff date
cutoff_date=$(calculate_cutoff_date)
echo "Cutoff date: $cutoff_date"

# Iterate through each certificate ID and get details
for cert_id in $cert_ids; do
  cert_data=$(get_certificate $cert_id)
  cert_details=$(extract_certificate_details "$cert_data" "$cert_id")
  cert_expiry_date=$(echo $cert_details | cut -d ',' -f 3)

  # Check if the certificate expiry date is within the specified number of days
  if [[ "$cert_expiry_date" < "$cutoff_date" ]]; then
    echo "$cert_details" >> $OUTPUT_CSV
  fi
done

echo "Certificate details saved to $OUTPUT_CSV."
echo "Certificate details extraction complete."