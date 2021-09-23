#!/bin/bash
##
## This script creates a zipped metadata package that can be deployed to an org
##

export TERM

source $(dirname $0)/config.sh
source $(dirname $0)/includes.sh

usage() {
  echo "Usage:"
  echo "    $0 [ -x ] [ outfile ]"
  echo "    $0 -h"
  echo "Parameters:"
  echo "  outfile     - The file to which to write the metadata package. Defaults to ${project_dir}/target/${project_name}.zip."
  echo "  -x          - Include destructive changes in the metadata package."
  echo "  -h          - Show help."
}

## stop on first error
set -e

build_dir="${project_dir}/target"
artifact_unzipped="${build_dir}/${project_name}"
artifact="${build_dir}/${project_name}.zip"
finalname=
destructive_changes=no
while getopts :xh arg; do
  case $arg in
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
if [ "x$1" != "x" ]; then
  finalname="$1"
  shift
  if [ "x$@" != "x" ]; then
    echo "Too many arguments: $@"
    usage
    exit 255
  fi
fi


mkdir -p "${build_dir}"

echo "${bold}Creating deployment package...${reset}"
rm -rf "${artifact_unzipped}"
mkdir -p "${artifact_unzipped}"
sfdx force:source:convert -d "${artifact_unzipped}" -r "${project_dir}/${source_dir}"

# Determine which Apex classes are marked for deletion (have a "//DELETE" line)
echo -n "${bold}Removing Apex classes marked as deleted from deployment package...${reset}"
members="$(grep -r '^\/\/ *DELETE$' ${artifact_unzipped}|awk -F':' '{print $1}'|while read line; do
  filename=`basename $line`
  ext=${filename##*.}
  sep=
  if [ "${ext}" == "cls" ]; then
    apexClass=`basename $filename .cls`
    echo "    <members>${apexClass}</members>"
    rm -f $line $line-meta.xml
    sed -i.bak "/<members>${apexClass}<\\/members>/d" ${artifact_unzipped}/package.xml
  fi
done)"
rm -f ${artifact_unzipped}/package.xml.bak
files_to_delete=`echo "${members}"|grep -c '<members>' || echo`
echo "${bold}${green} OK! ${files_to_delete} Apex classes(s) removed.${reset}"

if [ "${destructive_changes}" == "yes" ]; then
  echo -n "${bold}Adding destructive changes...${reset}"
  # Assemble the destructiveChanges.xml file
  cat >"${artifact_unzipped}/destructiveChangesPre.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
  <types>
    <name>ApexClass</name>
${members}
  </types>
</Package>
EOF
  echo "${bold}${green} OK! ${files_to_delete} file(s) added.${reset}"
fi

echo -n "${bold}Zipping package...${reset}"
pushd "${build_dir}" >/dev/null
rm -f "${artifact}" && zip -r "${artifact}" "${project_name}" >/dev/null
popd >/dev/null
if [ "x${finalname}" != "x" ]; then
  mkdir -p "`dirname "${finalname}"`"
  mv "${artifact}" "${finalname}"
else
  finalname="${artifact}"
fi

echo "${bold}${green} OK!${reset}"

echo
echo "${bold}Packaging successful! Package is in ${yellow}${finalname}${white}. To deploy, use:${reset}"
echo
echo "${yellow}sfdx ${white}force:mdapi:deploy ${green}-f${white} ${finalname} ${green}-u ${white}user@example.org ${reset}"
echo
