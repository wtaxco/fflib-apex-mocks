#!/bin/bash
##
## This script deploys the package source to an org
## Prerequisites:
## (*) A connection to the target org must already exist
##

export TERM

source $(dirname $0)/config.sh
source $(dirname $0)/includes.sh

usage() {
  echo "Usage:"
  echo "    $0 [ -f zipfile ] [ -u org ] [ -d ] [ -t | -T ] [ -p username ]... [ -w minutes ]"
  echo "    $0 -h"
  echo "Parameters:"
  echo "  -f zipfile  - A .zip file containing the metadata to deploy in metadata format. If omitted, the source"
  echo "                in ${source_dir} is deployed directly to the org."
  echo "  -u org      - Specifies the username or alias of the org to deploy to. If omitted, will deploy to the"
  echo "                org as indicated by the sfdx configuration variable 'defaultusername'".
  echo "  -d          - Deploy test data by running test data scripts in PROJECTDIR/scripts/data_scripts."
  echo "  -t          - Run project tests. Deploy will fail if any Apex class has less than 75% coverage."
  echo "                Either -t or -T can be specified, bot not both. Default is to run no tests."
  echo "  -T          - Run all org tests. Deploy will fail if coverage across all Apex classes is less than 75%."
  echo "                Either -t or -T can be specified, bot not both. Default is to run no tests."
  echo "  -p username - Assign this project's default permission set to the specified Salesforce user. Can be"
  echo "                repeated to assign the permission set to multiple users."
  echo "  -w minutes  - How long to wait for the deployment to finish. If the deployment takes longer than this, it will continue in the background."
  echo "  -x          - Perform destructive changes (i.e. deletes) on target org."
  echo "  -h          - Show help."
}

## stop on first error
set -e

zipfile=
runtests=no
deploytestdata=no
org=
org_name='<default>'
org_switch=
permset_delim=
wait=30
destructive_changes=no
while getopts :f:u:tTcdp:w:xh arg; do
  case $arg in
    u)
      org=$OPTARG
      ;;
    f)
      zipfile="$OPTARG"
      ;;
    t)
      if [ "x${runtests}" != "xno" ]; then
        echo "Cannot specify both -t and -T."
        exit 1
      fi
      runtests=project
      ;;
    T)
      if [ "x${runtests}" != "xno" ]; then
        echo "Cannot specify both -t and -T."
        exit 1
      fi
      runtests=org
      ;;
    d)
      deploytestdata=yes
      ;;
    p)
      permset_users="${permset_users}${permset_delim}${OPTARG}"
      permset_delim=,
      ;;
    w)
      wait="${OPTARG}"
      ;;
    x)
      destructive_changes=yes
      ;;
    h)
      usage
      exit
      ;;
    ?)
      echo "Invalid option: -${OPTARG}"
      usage
      exit 255
      ;;
  esac
done
shift $((OPTIND - 1))
if [ "x$@" != "x" ]; then
  echo "Too many arguments: $@"
  usage
  exit 255
fi
if [ "x${org}" != "x" ]; then
  org_name="${org}"
  org_switch="-u ${org}"
else
  org_name=`sfdx force:org:display |grep Username|awk '{print $2}'`
  if [ "x$org_name" == "x" ]; then
    exit 1
  fi
fi

# Delete Apex classes marked for deletion
if [ "${destructive_changes}" == "yes" ]; then
  # Determine which Apex classes are marked for deletion (have a "//DELETE" line)
  components="$(sep=; grep -r '^\/\/ *DELETE$' ${source_dir}|awk -F':' '{print $1}'|while read line; do
    filename=`basename $line`
    ext=${filename##*.}
    if [ "${ext}" == "cls" ]; then
      echo -n "${sep}ApexClass:`basename $filename .cls`"
      sep=,
    fi
  done)"
  # If we have a metadata zipfile, create a destructiveChangesPre.xml and add it to the zipfile
  if [ "x${components}" != "x" ]; then
    if [ "x${zipfile}" != "x" ]; then
      zipfile_absolute="$(cd "$(dirname "${zipfile}")"; pwd -P)/$(basename "${zipfile}")"
      echo -n "${bullet} ${bold}Adding destructive changes to metadata package...${reset}"
      # Retrieve the Apex classes from the org to see which ones actually exist there, as attempting a delete
      # on an Apex class that doesn't exist fails the deployment
      rm -rf delete && mkdir -p delete
      pushd delete >/dev/null
      cat <<EOF >sfdx-project.json
{
  "packageDirectories": [
    {
      "path": "${source_dir}"
    }
  ]
}
EOF
      mkdir ${source_dir}
      # force:source:retrieve requires an explicit -u orgname
      sfdx force:source:retrieve -u "${org_name}" -m "${components}" --json >>.log || (
        echo "${bold}${red} failed."
          tail .log
        exit 1
      )
      echo -n "${bold}...${reset}"
      # Check if anything was retrieved. If not, everything is already deleted and we can skip destructive changes
      number_of_files=`find ${source_dir} |wc -l`
      number_of_files=$(( number_of_files - 1))
      if [ ${number_of_files} -gt 0 ]; then
        # Convert to metadata format so we have a package.xml
        mkdir -p "${project_name}"
        sfdx force:source:convert -d "${project_name}" -r ${source_dir} --json >>.log || (
          echo "${bold}${red} failed."
          tail .log
          exit 1
        )
        echo -n "${bold}...${reset}"
        # Rename package.xml to destructiveChangesPre.xml
        files_to_delete=`grep -c '<members>' "${project_name}/package.xml"`
        mv "${project_name}/package.xml" "${project_name}/destructiveChangesPre.xml"
        # Add the destructiveChangesPre.xml to the zipfile
        # It will be deployed later
        zip -r "${zipfile_absolute}" "${project_name}/destructiveChangesPre.xml" >>.log || (
          echo "${bold}${red} failed."
          tail .log
          exit 1
        )
        echo "${bold}${green} Ok! Added ${files_to_delete} destructive changes.${reset}"
      else
        echo " No destructive changes to add.${reset}"
      fi
      popd >/dev/null
    else
      # No zipfile, just delete the classes with force:source:delete. This will fail on a production org.
      files_to_delete=`echo "${components}" | grep -o , | wc -l`
      files_to_delete=$((files_to_delete + 1))
      echo "${bold}Deleting ${files_to_delete} file(s) marked for deletion on ${org_name}...${reset}"
      sfdx force:source:delete -r -m ${components} ${org_switch}
    fi
  fi
fi

echo "${bold}Deploying to ${org_name}...${reset}"
if [ "x${runtests}" = "xproject" ]; then
  # Run project tests only
  # - Determine list of project tests
  delim=
  testlist=$(find ${source_dir}/test -name '*.cls' | while read test; do
    if ! grep -c '^\/\/ *DELETE$' "${test}" >/dev/null; then
      echo -n "${delim}`basename ${test} .cls`"
      delim=,
    fi
  done)
  echo "${bold}Tests to run:${reset}" `echo "$testlist" | sed -e 's/,/, /g'`
  if [ "x${zipfile}" != "x" ]; then
    echo "${bullet} ${bold}Validating deployment...${reset}"
    sfdx force:mdapi:deploy -c -l RunSpecifiedTests -r "${testlist}" -f "${zipfile}" ${org_switch} -w ${wait} || exit 1
    deploymentId=`sfdx force:mdapi:deploy:report ${org_switch} --json|jq -r '.result.id'`
    echo "${bullet} ${bold}Quick-deploying...${reset}"
    sfdx force:mdapi:deploy -q "${deploymentId}" ${org_switch} -w ${wait}
  else
    echo "${bold}${yellow}* ${bold}Validating deployment...${reset}"
    sfdx force:source:deploy -c -l RunSpecifiedTests -r "${testlist}" -p ${project_dir}/${source_dir} ${org_switch} -w ${wait} || exit 1
    deploymentId=`sfdx force:source:deploy:report ${org_switch} --json|jq -r '.result.id'`
    echo "${bold}${yellow}* ${bold}Quick-deploying...${reset}"
    sfdx force:source:deploy -q "${deploymentId}" ${org_switch} -w ${wait} || exit 1
  fi
elif [ "x${runtests}" = "xorg" ]; then
  # Run local org tests
  if [ "x${zipfile}" != "x" ]; then
    echo "${bullet} ${bold}Validating deployment...${reset}"
    sfdx force:mdapi:deploy -c -l RunLocalTests -f "${zipfile}" ${org_switch} -w ${wait} || exit 1
    deploymentId=`sfdx force:mdapi:deploy:report ${org_switch} --json|jq -r '.result.id'`
    echo "${bullet} ${bold}Quick-deploying...${reset}"
    sfdx force:mdapi:deploy -q "${deploymentId}" ${org_switch} -w ${wait}
  else
    echo "${bullet} ${bold}Validating deployment...${reset}"
    sfdx force:source:deploy -c -l RunLocalTests -p ${project_dir}/${source_dir} ${org_switch} -w ${wait} || exit 1
    deploymentId=`sfdx force:source:deploy:report ${org_switch} --json|jq -r '.result.id'`
    echo "${bullet} ${bold}Quick-deploying...${reset}"
    sfdx force:source:deploy -q "${deploymentId}" ${org_switch} -w ${wait} || exit 1
  fi
  sfdx force
else
  # Deploy without running tests -- will fail on production orgs
  if [ "x${zipfile}" != "x" ]; then
    echo "${bullet} ${bold}Validating deployment...${reset}"
    sfdx force:mdapi:deploy -c -f "${zipfile}" ${org_switch} -w ${wait} || exit 1
    deploymentId=`sfdx force:mdapi:deploy:report ${org_switch} --json|jq -r '.result.id'`
    echo "${bullet} ${reset}${bold}Quick-deploying...${reset}"
    sfdx force:mdapi:deploy -q "${deploymentId}" ${org_switch} -w ${wait}
  else
    echo "${bullet} ${reset}${bold}Validating deployment...${reset}"
    sfdx force:source:deploy -c -p ${project_dir}/${source_dir} ${org_switch} -w ${wait} || exit 1
    deploymentId=`sfdx force:source:deploy:report ${org_switch} --json|jq -r '.result.id'`
    echo "${bullet} ${reset}${bold}Quick-deploying...${reset}"
    sfdx force:source:deploy -q "${deploymentId}" ${org_switch} -w ${wait} || exit 1
  fi
fi

if [ "x${deploytestdata}" == "xyes" -a -d ${project_dir}/data-scripts ]; then
  echo "${bold}Deploying test data scripts...${reset}"
  sfdx force:source:deploy -p ${project_dir}/data-scripts ${org_switch}
  echo "${bold}Running test data scripts...${reset}"
  echo "${bullet} ${bold}Running data scripts to create test data...${reset}"
  for data_script in ${project_dir}/scripts/data_scripts/*.apex; do
    run_data_script "${data_script}"
  done
fi

# TODO Run migration scripts

if [ "x${permset_users}" != "x" ]; then
  echo
  echo "${bold}Assigning permissions...${reset}"
  sfdx force:user:permset:assign -n ${permset} ${org_switch} -o "${permset_users}"
fi

echo
echo "${green}Done!${reset}"
