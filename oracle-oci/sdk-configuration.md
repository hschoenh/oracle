# Local OCI Configuration Tutorial (including validation)
Create local OCI CLI configuration (the ~/.oci/config file on your Mac/laptop) – the classic way using API key, tenancy OCID etc. 

## Prerequisites
1. Installing the OCI CLI
2. Creating the API keys
3. Creating the ~/.oci/config file
4. Checking permissions
5. Validation with some useful tests
6. Optional: multiple profiles

### 1. Prerequisites

Access to an OCI account (console login works)

Permissions to:
- view a user
- add an API key to the user

On your local machine:
- Python or the OCI CLI install script (Mac/Linux)
- Terminal access

### 2. Install OCI CLI
macOS / Linux (standard way)
Terminal:
```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```
Typically:
- Install to something like ~/lib/oracle-cli
- Add a symlink to ~/bin/oci or ~/.local/bin/oci
- Restart the terminal or adjust your PATH
```bash
oci --version
```
### 3. Create API keys (RSA key pair)
Use the “classic” way with OpenSSL:
```bash
mkdir -p ~/.oci
cd ~/.oci
# Private key
openssl genrsa -out oci_api_key.pem 2048
# Public key
openssl rsa -pubout -in oci_api_key.pem -out oci_api_key_public.pem
```
Fix file permissions:
```bash
chmod 600 ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key_public.pem
```
### Upload public key in the OCI Console

Log in to the OCI Console.
- Click your user (profile) in the top right → User settings.
- Go to API Keys → Add API Key.
- Paste the content of oci_api_key_public.pem:
```bash
cat ~/.oci/oci_api_key_public.pem
```
### After saving, OCI shows you:
- Key fingerprint
- A config snippet (you can reuse that for your config file)
- You’ll need these values in the next step.
### 4. Create ~/.oci/config
Create or edit the file:
```bash
vi ~/.oci/config
```
```bash
[DEFAULT]
user=ocid1.user.oc1..aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tenancy=ocid1.tenancy.oc1..aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
region=eu-frankfurt-1
fingerprint=aa:bb:c....
key_file=~/.oci/oci_api_key.pem
```
Field explanations:

user: OCID of your user (Console → User → Details)
tenancy: Tenancy OCID (Console → Tenancy details)
region: e.g. eu-frankfurt-1, eu-zurich-1, etc.
fingerprint: fingerprint of the API key (shown next to the API key in the console)
key_file: path to oci_api_key.pem

Save the file.

### 5. Check file permissions
OCI is strict here.
```bash
chmod 600 ~/.oci/config
```
Optional Check:
```bash
ls -l ~/.oci
```
Important: config and oci_api_key.pem must not be world-readable.

### 6. Validation – step by step
Now the interesting part: verifying that everything works.
### 6.1. Simple identity check
```bash
oci iam region list
```
If your configuration is correct, you’ll get a list of available regions.
If something is wrong with the key or config, you’ll see for example:

Auth error (NotAuthenticated)
Permission error (NotAuthorizedOrNotFound)
### 6.2. Who am I?
```bash
oci iam user list --all \
  --query 'data[].{Name:"name", OCID:"id", Description:"description", State:"lifecycle-state", TimeCreated:"time-created"}' \
  --output table
```
Typical error patterns:
NotAuthorizedOrNotFound: user doesn’t have enough permissions (missing policy)
Authentication errors: wrong config/key
This helps you distinguish between:
Technical issue (key/config wrong)
Authorization issue (IAM / policies)
### 7. Optional: use multiple profiles
When you often work with multiple tenancies/environments. The usual way is multiple profiles in a single config file.
Example:
```Bash
[DEFAULT]
user=ocid1.user.oc1..user-default
tenancy=ocid1.tenancy.oc1..tenancy-default
region=eu-zurich-1
fingerprint=11:22:...
key_file=/Users/user/.oci/oci_api_key.pem

[LAB]
user=ocid1.user.oc1..user-lab
tenancy=ocid1.tenancy.oc1..tenancy-lab
region=eu-frankfurt-1
fingerprint=aa:bb:...
key_file=/Users/user/.oci/oci_api_key_lab.pem
```
Call with profile:
```bash
oci --profile LAB iam region list
```
That way you keep environments clearly separated, which is the traditional and robust way in larger setups.

### Short “mini checklist”

- Install OCI CLI → oci --version
- Create RSA key pair → oci_api_key.pem + oci_api_key_public.pem
- Upload the public key to your user in the OCI Console
- Create ~/.oci/config with user, tenancy, region, fingerprint, key_file
- Set permissions → chmod 600 ~/.oci/config ~/.oci/oci_api_key.pem

Validate:
- oci iam region list
- oci iam user get --user-id <USER_OCID>
- oci iam compartment list --compartment-id <TENANCY_OCID>

That gives you a clean local OCI configuration including functional validation, following the same patterns that have been used reliably for years.
