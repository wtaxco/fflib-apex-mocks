# Set some constants for colors
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
blue=$(tput setaf 4)
cyan=$(tput setaf 6)
white=$(tput setaf 7)
bold=$(tput bold)
underline="\033[4m"
reset=$(tput sgr0)
# and some formatting elements based on them
bullet="${bold}${cyan}(${yellow}*${cyan})${reset}"

# Set paths to script and project
script_dir=`dirname $0`
project_dir=$(cd ${script_dir}; pwd)

echo -n "${bold}Checking for sfdx... ${reset}"
sfdx_bin=$(which sfdx)
if [ "x${sfdx_bin}" == "x" ]; then
  echo "${red} not found.${reset}"
  echo
  echo "${red}Salesforce DX was not found. Please go to"
  echo -e "${blue}${underline}https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm${reset}"
  echo "${red}and follow the instructions there.${reset}"
  exit 2
else
  echo "${green}OK, found ${sfdx_bin}.${reset}"
fi
echo -n "${bold}Checking for jq... ${reset}"
jq_bin=$(which jq)
if [ "x${jq_bin}" == "x" ]; then
  echo "${red} not found.${reset}"
  echo
  echo "${red}jq was not found. Please go to"
  echo -e "${blue}${underline}https://stedolan.github.io/jq/download/${reset}"
  echo "${red}and follow the instructions there to install it.${reset}"
  exit 2
else
  echo "${green}OK, found ${jq_bin}.${reset}"
fi
echo

function get_org_id() {
  sfdx force:org:display|grep '^Id'|awk '{print $2}'
}

###
# Usage: execute_apex file [ sfdxoption [...] ]
# Executes file as an anonymous Apex file using sfdx force:apex:execute, sending the output to
# .log in the current directory. All sfdxoption arguments are passed verbatim to the sfdx command.
#
# Exit code:
# - 0 if the Apex code executed successfully
# - 1 if the Apex code exited with an error, shown by a FATAL_ERROR line in .log
function execute_apex() {
  script="$1"
  shift 1
  if sfdx force:apex:execute -f "${script}" "$@" >.log; then
    if ! grep -c FATAL_ERROR <.log >/dev/null; then
      return 0
    else
      return 1
    fi
  else
    return 255
  fi
}

function run_data_script {
  datascript="$1"
  echo -e "Data script: $datascript"
  success=0
  retries=3
  while [ ${retries} -gt 0 ]; do
    if execute_apex "$datascript" ${org_switch}; then
      success=1
      break;
    else
      retries=$((retries - 1))
      if [ ${retries} -gt 0 ]; then
        echo "${red}${bold}Failed to run $datascript, retrying (${retries})...${reset}"
      fi
    fi
  done
  if [ ${success} == 0 ]; then
    echo "${red}${bold}Failed $datascript ${reset}"
    cat .log
    exit 1
  else
    echo "${green}${bold}Finished $datascript ${reset}"
  fi
  echo
}
