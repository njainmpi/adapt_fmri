#!/usr/bin/env bash

clear 
set -Eeuo pipefail
set -o errtrace
PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}: '
trap 'code=$?; echo "ERROR: command \"${BASH_COMMAND}\" exited $code at ${BASH_SOURCE[0]}:${LINENO}"; exit $code' ERR

# --- ensure bash ---
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "Please run this script with bash (not sh)." >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 127; }; }
need curl; need awk; need python3; command -v column >/dev/null 2>&1 || true
need mktemp

shopt -s nullglob

# --- Expand user paths safely ---
expand_path() {
  python3 - "$1" <<'PY_EXPAND'
import os, sys
p = sys.argv[1] if len(sys.argv)>1 else ''
print(os.path.abspath(os.path.expanduser(os.path.expandvars(p or '.'))))
PY_EXPAND
}

# --- read_default helper with tab completion ---
read_root_with_completion() {
  local prompt="$1" default="$2" outvar="$3" input
  bind 'set show-all-if-ambiguous on' >/dev/null 2>&1 || true
  bind 'TAB:menu-complete' >/dev/null 2>&1 || true
  read -e -p "${prompt} [${default}]: " input
  printf -v "$outvar" "%s" "${input:-$default}"
}

# --- Color helpers ---
BOLD_CYAN="\033[1;36m"; DIM_GRAY="\033[90m"; WHITE="\033[37m"
RESET="\033[0m"; YELLOW="\033[33m"; RED="\033[31m"; GREEN="\033[32m"; CYAN="\033[36m"

# =====================================================================
# List functions directly from a GitHub .sh file without sourcing it
# =====================================================================
list_functions_in_file() {
  local repo_path="$1"      # e.g. "njainmpi/fMRI_analysis_pipeline"
  local file_path="$2"      # e.g. "motion_correction.sh"
  local branch="${3:-main}" # optional branch name

  local raw_url="https://raw.githubusercontent.com/${repo_path}/${branch}/${file_path}"

  echo -e "${BOLD_CYAN}Fetching:${RESET} ${file_path}"
  if ! curl -fsSL "$raw_url" | \
      grep -E '^[[:space:]]*[a-zA-Z0-9_]+\s*\(\)\s*\{' | \
      sed -E 's/^[[:space:]]*([a-zA-Z0-9_]+)\s*\(\)\s*\{/\1/' | \
      sort -u; then
    echo -e "${RED}Failed to fetch or parse functions from:${RESET} ${file_path}"
  fi
}


# =====================================================================
# GitHub function loader (gh_source)
# =====================================================================
gh_source() {
  # Usage: gh_source <user/repo> <path/in/repo> [branch]
  local repo_path="$1" file_path="$2" branch="${3:-main}"
  local raw_url="https://raw.githubusercontent.com/${repo_path}/${branch}/${file_path}"

  # Temporary file
  local temp_file
  temp_file=$(mktemp)

  if curl -fsSL "$raw_url" -o "$temp_file"; then
    if bash -n "$temp_file" 2>/dev/null; then
      # shellcheck disable=SC1090
      source "$temp_file"
      echo -e "${GREEN}Loaded functions from:${RESET} ${file_path}"
    else
      echo -e "${RED}Syntax check failed for:${RESET} ${file_path}"
    fi
  else
    echo -e "${RED}Failed to fetch:${RESET} $raw_url"
  fi
}

gh_source "njainmpi/fMRI_analysis_pipeline" "toolbox_name.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "temporal_smoothing.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "missing_run.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "func_parameters_extraction.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "data_conversion.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "motion_correction.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "smoothing_using_fsl.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "temporal_snr_using_afni.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "temporal_snr_using_fsl.sh"
gh_source "njainmpi/fMRI_analysis_pipeline" "scm_from_coregsitered_functional_v1.sh"

 # =====================================================================
# Root location prompt (tab completion)
# =====================================================================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
default_root="/Volumes/pr_ohlendorf/fMRI"

root_location="${1:-}"
if [[ "${root_location:-}" == "--root" ]]; then shift; root_location="${1:-}"; shift || true; fi
if [[ -z "${root_location:-}" ]]; then
  read_root_with_completion "Root location" "${default_root}" root_location_input
  root_location="${root_location_input}"
fi
root_location="$(expand_path "$root_location")"
[[ -d "$root_location" ]] || { echo -e "${RED}ERROR:${RESET} root location '$root_location' does not exist."; exit 1; }
echo -e "${BOLD_CYAN}Using root location:${RESET} $root_location"

# =====================================================================
# Dataset discovery (grouped by Month-Year)
# =====================================================================
echo -e "${BOLD_CYAN}=== Searching for valid datasets under $root_location ===${RESET}"

DATASETS=()
while IFS= read -r d; do
  if [[ -f "$d/acqp" && -f "$d/method" && -f "$d/visu_pars" && -f "$d/pulseprogram" && -d "$d/pdata" ]]; then
    DATASETS+=("$(dirname "$d")")
  fi
done < <(find "$root_location" -type d -mindepth 2 -maxdepth 6 2>/dev/null)
DATASETS=($(printf "%s\n" "${DATASETS[@]}" | sort -u))

# Sort descending by scan date
DATASETS=($(for ds in "${DATASETS[@]}"; do
  base=$(basename "$ds"); dateprefix="${base%%_*}"
  printf "%s|%s\n" "$dateprefix" "$ds"
done | sort -t'|' -k1,1r | cut -d'|' -f2))

if ((${#DATASETS[@]} == 0)); then
  echo -e "${RED}No valid datasets found under $root_location.${RESET}"
  exit 1
fi

printf "\n"
tmpfile=$(mktemp)

month_name_from_num() {
  local m="$1" result=""
  if [[ "$(uname)" == "Darwin" ]]; then
    result="$(date -j -f "%m" "$m" +"%B" 2>/dev/null || true)"
  else
    result="$(date -d "2020-$m-01" +"%B" 2>/dev/null || true)"
  fi
  [[ -z "$result" ]] && result="Unknown"
  echo "$result"
}

for ds in "${DATASETS[@]}"; do
  base=$(basename "$ds"); dateprefix="${base%%_*}"
  if [[ "$dateprefix" =~ ^[0-9]{8}$ ]]; then
    year="${dateprefix:0:4}"; month="${dateprefix:4:2}"
    monthname="$(month_name_from_num "$month")"
    printf "%s|%s|%s\n" "$year-$month" "$monthname $year" "$ds" >> "$tmpfile"
  fi
done

sort -r -t'|' -k1,1 "$tmpfile" -o "$tmpfile"

index=1; current_group=""
total_count=$(wc -l < "$tmpfile" | tr -d ' ')
echo -e "${BOLD_CYAN}Found $total_count datasets in total${RESET}"

while IFS='|' read -r ymonth key ds; do
  if [[ "$key" != "$current_group" ]]; then
    [[ -n "$current_group" ]] && printf "\n"
    current_group="$key"
    count=$(grep -c "^$ymonth|" "$tmpfile")
    echo -e "\n${BOLD_CYAN}${key} (${count} dataset$([[ $count -gt 1 ]] && echo "s"))${RESET}"
    echo -e "${DIM_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  fi

  runs=$(find "$ds" -type d -depth 1 2>/dev/null | grep -E "/[0-9]+$" | wc -l | tr -d ' ')
  [[ "$runs" -eq 0 ]] && runs="?"
  subj_file="$ds/subject"
  subject_id="[Not found]"
  study_name="[Not found]"
  if [[ -f "$subj_file" ]]; then
    id_line=$(awk 'NR==14 {gsub(/[<>]/, "", $0); print; exit}' "$subj_file" 2>/dev/null || true)
    [[ -n "$id_line" ]] && subject_id="$id_line"
    study_line=$(awk 'NR==25 {gsub(/[<>]/, "", $0); print; exit}' "$subj_file" 2>/dev/null || true)
    [[ -n "$study_line" ]] && study_name="$study_line"
  fi
  printf "${YELLOW}%-6d${RESET} ${GREEN}%-80s${RESET} (${runs} runs)\n" "$index" "$(basename "$ds")"
  printf "       ${DIM_GRAY}Subject ID:${RESET} ${WHITE}%s${RESET} | ${DIM_GRAY}Study:${RESET} ${WHITE}%s${RESET}\n" "$subject_id" "$study_name"
  ((index++))
done < "$tmpfile"

# After sorting and printing datasets
# Rebuild DATASETS[] in *exactly the printed order*
DATASETS=()
while IFS='|' read -r ymonth key ds; do
  DATASETS+=("$ds")
done < "$tmpfile"

rm -f "$tmpfile"
printf "\n"


# =====================================================================
# Dataset selection
# =====================================================================
read -rp "Enter dataset indices to process (e.g. 1,3,5-7 or q to quit): " sel
case "$sel" in q|Q) echo "Aborted."; exit 0 ;; esac
[[ -n "$sel" ]] || { echo -e "${RED}No selection.${RESET}"; exit 1; }

expand_lines() {
  local input="$1" part a b n
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${part%-*}"; b="${part#*-}"; ((a>b)) && { n="$a"; a="$b"; b="$n"; }
      for (( n=a; n<=b; n++ )); do echo "$n"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then echo "$part"; fi
  done | sort -n | uniq
}

LINES=()
while IFS= read -r ln; do
  (( ln >= 1 && ln <= ${#DATASETS[@]} )) && LINES+=("$ln")
done < <(expand_lines "$sel")
((${#LINES[@]})) || { echo -e "${RED}No valid dataset indices.${RESET}"; exit 1; }

# =====================================================================
# Process each dataset + Summary
# =====================================================================
SUMMARY_TABLE=()

process_dataset() {
  local idx="$1"; local datapath="${DATASETS[$((idx-1))]}"
  echo -e "${BOLD_CYAN}=== Processing dataset [$idx]: $(basename "$datapath") ===${RESET}"

  local subj_file="$datapath/subject"
  local subject_id="[Unknown]"
  if [[ -f "$subj_file" ]]; then
    subject_id=$(awk 'NR==14 {gsub(/[<>]/, "", $0); print; exit}' "$subj_file" 2>/dev/null || echo "[Unknown]")
  fi

  echo -e "\n${BOLD_CYAN}───────────────────────────────────────────────────────────────${RESET}"
  echo -e "${BOLD_CYAN}Run Information for Subject: ${WHITE}${subject_id}${RESET}"
  echo -e "${BOLD_CYAN}───────────────────────────────────────────────────────────────${RESET}\n"

  printf "${YELLOW}%-6s | %-20s | %-15s | %-15s${RESET}\n" "Run" "Sequence Name" "No. of Averages" "No. of Repetitions"
  printf "${DIM_GRAY}%s${RESET}\n" "------+----------------------+-----------------+-------------------"

  find "$datapath" -maxdepth 1 -mindepth 1 -type d 2>/dev/null |
    awk -F/ '/\/[0-9]+$/ {print $NF "|" $0}' |
    sort -t'|' -k1,1n |
    cut -d'|' -f2 |
    while read -r run_dir; do
      run_name=$(basename "$run_dir")
      acqp_file="$run_dir/acqp"
      method_file="$run_dir/method"
      seq_name="-"; na="-"; nr="-"
      if [[ -f "$acqp_file" ]]; then
        seq_name=$(awk -F'[<>]' '/^##\$ACQ_protocol_name=/{getline; print $2; exit}' "$acqp_file" 2>/dev/null || echo "-")
      fi
      if [[ -f "$method_file" ]]; then
        na=$(grep -m1 "^##\$PVM_NAverages=" "$method_file" | awk -F= '{print $2}' || echo "-")
        nr=$(grep -m1 "^##\$PVM_NRepetitions=" "$method_file" | awk -F= '{print $2}' || echo "-")
      fi
      highlight=""
      seq_upper="$(echo "$seq_name" | tr '[:lower:]' '[:upper:]')"
      [[ "$na" =~ ^[0-9]+$ ]] && na_num="$na" || na_num=0
      [[ "$nr" =~ ^[0-9]+$ ]] && nr_num="$nr" || nr_num=0
      if { [[ "$na_num" -gt 1 || "$nr_num" -gt 1 ]] && \
           { [[ "$nr_num" -gt 1 ]] || { [[ ! "$seq_upper" =~ FLASH ]] && [[ ! "$seq_upper" =~ EPI ]]; }; }; }; then
        highlight="\033[1;31m"
      fi
      printf "${highlight}%-6s | ${CYAN}%-20s${RESET}${highlight} | %-15s | %-15s${RESET}\n" \
        "$run_name" "$seq_name" "$na" "$nr"
    done
  echo
  echo -e "${BOLD_CYAN}───────────────────────────────────────────────────────────────${RESET}\n"

  # ======================= interactive pairing ======================
  local options=("Multiple functional → Single structural"
                 "Single functional → Multiple structural"
                 "Multiple functional → Multiple structural"
                 "Single functional → Single structural")
  local choice=0 key
  echo -e "${YELLOW}Select how functional and structural runs should be paired:${RESET}"
  while true; do
    for i in "${!options[@]}"; do
      if (( i == choice )); then printf "  ${BOLD_CYAN}> %s${RESET}\n" "${options[$i]}"; else printf "    %s\n" "${options[$i]}"; fi
    done
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then read -rsn2 key
      case $key in '[A') ((choice--)); ((choice<0))&&choice=3;; '[B') ((choice++)); ((choice>3))&&choice=0;; esac
    elif [[ $key == "" ]]; then break; fi
    printf "\033[%dA" $(( ${#options[@]} ))
  done
  echo -e "\n${BOLD_CYAN}You selected:${RESET} ${options[$choice]}\n"

  case $choice in
    0) echo -e "${YELLOW}Enter multiple functional run numbers:${RESET}"
       read -rp "Functional Runs: " func_input
       echo -e "${YELLOW}Enter one structural run number:${RESET}"
       read -rp "Structural Run: " struct_input;;
    1) echo -e "${YELLOW}Enter one functional run number:${RESET}"
       read -rp "Functional Run: " func_input
       echo -e "${YELLOW}Enter multiple structural run numbers:${RESET}"
       read -rp "Structural Runs: " struct_input;;
    2) echo -e "${RED}Multiple→Multiple not supported yet.${RESET}\n"; process_dataset "$idx"; return 0;;
    3) echo -e "${YELLOW}Enter one functional run number:${RESET}"
       read -rp "Functional Run: " func_input
       echo -e "${YELLOW}Enter one structural run number:${RESET}"
       read -rp "Structural Run: " struct_input;;
  esac

  run_number=$(echo "$func_input" | tr ',' ' ' | xargs)
  str_for_coreg=$(echo "$struct_input" | tr ',' ' ' | xargs)

  echo -e "\n${BOLD_CYAN}Assigned Variables:${RESET}"
  echo -e "  run_number    = ${GREEN}${run_number}${RESET}"
  echo -e "  str_for_coreg = ${GREEN}${str_for_coreg}${RESET}"

  # ==================== persistent mapping ==========================
  MAP_FILE="$root_location/.fmri_project_map.json"
  export MAP_FILE
  [[ ! -f "$MAP_FILE" ]] && echo "{}" > "$MAP_FILE"

  existing_mapping=$(python3 - <<'PY_LOAD'
import json, sys, os
f=os.environ.get("MAP_FILE")
if f and os.path.exists(f):
    with open(f) as fh:
        data=json.load(fh)
        print(json.dumps(data))
else:
    print("{}")
PY_LOAD
)

  dataset_path="$datapath"
  project=""; subproject=""
  assigned=$(python3 - <<PY_CHECK
import json
data=json.loads('''$existing_mapping''')
p="$dataset_path"
if p in data:
    print(f"{data[p]['project']}|{data[p]['subproject']}")
PY_CHECK
)

  if [[ -n "$assigned" ]]; then
    project="${assigned%%|*}"; subproject="${assigned#*|}"
    echo -e "\n${GREEN}Dataset already assigned:${RESET}"
    echo -e "  Project    : ${CYAN}${project}${RESET}"
    echo -e "  Subproject : ${CYAN}${subproject}${RESET}"
  else
    echo -e "\n${YELLOW}Assign dataset to project and subproject:${RESET}"

    # --- List existing projects (arrow menu) ---
    existing_projects=$(python3 - <<PY_LIST
import json
data=json.loads('''$existing_mapping''')
projects=sorted(set(v['project'] for v in data.values())) if data else []
print("\\n".join(projects))
PY_LIST
)

    if [[ -n "$existing_projects" ]]; then
      echo -e "\n${YELLOW}Use ↑/↓ and Enter to choose a project:${RESET}"
      project_list=()
      while IFS= read -r line; do [[ -n "$line" ]] && project_list+=("$line"); done <<< "$existing_projects"
      project_list+=("Other (new project)")
      choice=0; key=""
      while true; do
        for i in "${!project_list[@]}"; do
          if (( i == choice )); then
            printf "  ${BOLD_CYAN}> %s${RESET}\n" "${project_list[$i]}"
          else
            printf "    %s\n" "${project_list[$i]}"
          fi
        done
        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then read -rsn2 key
          case $key in
            '[A') ((choice--)); ((choice<0))&&choice=${#project_list[@]}-1;;
            '[B') ((choice++)); ((choice>=${#project_list[@]}))&&choice=0;;
          esac
        elif [[ $key == "" ]]; then
          project="${project_list[$choice]}"
          break
        fi
        printf "\033[%dA" "${#project_list[@]}"
      done
      if [[ "$project" == "Other (new project)" ]]; then
        read -rp "Enter New Project Name: " project
      fi
    else
      read -rp "Enter Project Name: " project
    fi

    # --- Subproject (arrow menu) ---
    existing_subprojects=$(python3 - <<PY_SUBLIST
import json
data=json.loads('''$existing_mapping''')
subs=sorted(set(v['subproject'] for v in data.values() if v['project']=="$project"))
print("\\n".join(subs))
PY_SUBLIST
)

    if [[ -n "$existing_subprojects" ]]; then
      echo -e "\n${YELLOW}Use ↑/↓ and Enter to choose a subproject:${RESET}"
      sub_list=()
      while IFS= read -r line; do [[ -n "$line" ]] && sub_list+=("$line"); done <<< "$existing_subprojects"
      sub_list+=("Other (new subproject)")
      choice=0; key=""
      while true; do
        for i in "${!sub_list[@]}"; do
          if (( i == choice )); then
            printf "  ${BOLD_CYAN}> %s${RESET}\n" "${sub_list[$i]}"
          else
            printf "    %s\n" "${sub_list[$i]}"
          fi
        done
        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then read -rsn2 key
          case $key in
            '[A') ((choice--)); ((choice<0))&&choice=${#sub_list[@]}-1;;
            '[B') ((choice++)); ((choice>=${#sub_list[@]}))&&choice=0;;
          esac
        elif [[ $key == "" ]]; then
          subproject="${sub_list[$choice]}"
          break
        fi
        printf "\033[%dA" "${#sub_list[@]}"
      done
      if [[ "$subproject" == "Other (new subproject)" ]]; then
        read -rp "Enter New Subproject Name: " subproject
      fi
    else
      read -rp "Enter Subproject Name: " subproject
    fi

    # --- Save mapping ---
    python3 - <<PY_WRITE
import json, os
f=os.environ.get("MAP_FILE")
data={}
if os.path.exists(f):
    with open(f) as fh: data=json.load(fh)
data["$dataset_path"]={"project":"$project","subproject":"$subproject"}
with open(f,"w") as fh: json.dump(data,fh,indent=2)
print("Saved mapping to",f)
PY_WRITE
  fi

  # --- Append summary info ---
  SUMMARY_TABLE+=("$datapath|$(basename "$datapath")|$subject_id|$project|$subproject|$run_number|$str_for_coreg")
}

for ln in "${LINES[@]}"; do
  process_dataset "$ln"
done
# =====================================================================
# Summary Table (Perfectly Aligned, Fixed Widths)
# =====================================================================
printf "\n${BOLD_CYAN}=================================================================================================================================${RESET}\n"
printf "${BOLD_CYAN}                                                                Dataset Summary              ${RESET}\n"
printf "${BOLD_CYAN}=================================================================================================================================${RESET}\n\n"

# Helper to truncate long text safely
truncate_text() {
  local str="$1" maxlen="$2"
  if (( ${#str} > maxlen )); then
    printf "%s..." "${str:0:maxlen-3}"
  else
    printf "%s" "$str"
  fi
}

count=1
for entry in "${SUMMARY_TABLE[@]}"; do
  IFS='|' read -r datapath dname subj proj subproj func struct <<< "$entry"

  echo -e "${DIM_GRAY}Dataset Path:${RESET} ${WHITE}$datapath${RESET}\n"

  # --- Column widths ---
  w_no=4
  w_name=62
  w_subj=30
  w_proj=30
  w_subproj=30
  w_func=15
  w_struct=15

  # --- Header ---
  printf "${YELLOW}%-${w_no}s | %-$(($w_name))s | %-$(($w_subj))s | %-$(($w_proj))s | %-$(($w_subproj))s | %-$(($w_func))s | %-$(($w_struct))s${RESET}\n" \
    "No." "Dataset Name" "Subject ID" "Project" "Subproject" "Func Run" "Struct Run"

  printf "${DIM_GRAY}%s${RESET}\n" \
    "-----|----------------------------------------------------------------|--------------------------------|--------------------------------|--------------------------------|-----------------|-----------------"

  # --- Truncate per field ---
  dname_trunc=$(truncate_text "$dname" $w_name)
  subj_trunc=$(truncate_text "$subj" $w_subj)
  proj_trunc=$(truncate_text "$proj" $w_proj)
  subproj_trunc=$(truncate_text "$subproj" $w_subproj)
  func_trunc=$(truncate_text "$func" $w_func)
  struct_trunc=$(truncate_text "$struct" $w_struct)

  # --- Data Row ---
  printf "%-${w_no}s | %-$(($w_name))s | %-$(($w_subj))s | %-$(($w_proj))s | %-$(($w_subproj))s | %-$(($w_func))s | %-$(($w_struct))s\n" \
    "$count" "$dname_trunc" "$subj_trunc" "$proj_trunc" "$subproj_trunc" "$func_trunc" "$struct_trunc"

  printf "${DIM_GRAY}%s${RESET}\n\n" \
    "-----|----------------------------------------------------------------|--------------------------------|--------------------------------|--------------------------------|-----------------|-----------------"
  ((count++))
done


# =====================================================================
# Create folder hierarchy for analysed data
# =====================================================================
echo -e "\n${BOLD_CYAN}Checking/creating AnalysedData directory structure...${RESET}\n"

for entry in "${SUMMARY_TABLE[@]}"; do
  IFS='|' read -r datapath dname subj proj subproj func struct <<< "$entry"

  # Define target path
  target_dir="${root_location}/AnalysedData/${proj}/${subproj}/${subj}"

  # Create the directory tree if not existing
  if [[ ! -d "$target_dir" ]]; then
    mkdir -p "$target_dir"
    echo -e "${GREEN}Created:${RESET} $target_dir"
  else
    echo -e "${DIM_GRAY}Exists:${RESET} $target_dir"
  fi
done

echo -e "\n${GREEN}All required directories verified/created successfully.${RESET}\n"



echo -e "${GREEN}Summary table complete.${RESET}\n"


# =====================================================================
# Basic Data Processing: Create run-level subfolders
# =====================================================================

printf "\n${BOLD_CYAN}=================================================================================================================================${RESET}\n"
printf "${BOLD_CYAN}                                                       Starting Basic Data Processing setup...              ${RESET}\n"
printf "${BOLD_CYAN}=================================================================================================================================${RESET}\n\n"


echo -e "\n${BOLD_CYAN}Starting Basic Data Processing setup...${RESET}\n"

for entry in "${SUMMARY_TABLE[@]}"; do
  IFS='|' read -r datapath dname subj proj subproj func struct <<< "$entry"
  base_target="${root_location}/AnalysedData/${proj}/${subproj}/${subj}"

  # Create base if missing (failsafe)
  mkdir -p "$base_target"

  # Process functional runs
    for run in $func; do
      run_dir="${datapath}/${run}"
      if [[ -d "$run_dir" ]]; then
        seq_name=$(awk -F'[<>]' '/^##\$ACQ_protocol_name=/{getline; print $2; exit}' "$run_dir/acqp" 2>/dev/null || echo "UnknownSequence")
        clean_seq=$(echo "$seq_name" | tr -cd '[:alnum:]_-' | cut -c1-50)
        func_path_analysed="${base_target}/${run}${clean_seq}"
        mkdir -p "$func_path_analysed"
        echo -e "  ${CYAN}Created Functional:${RESET} $func_path_analysed"

        # ===========================================================
        # Convert Bruker → NIfTI if missing, then copy reference file
        # ===========================================================
        pushd "$func_path_analysed" >/dev/null || exit 1
        
        run_if_missing "G1_cp.nii.gz" -- BRUKER_to_NIFTI "$datapath" "$run" "$datapath/$run/method"
        echo -e "${YELLOW}WARNING:${RESET} G1_cp.nii.gz not found for functional; continuing."

        popd >/dev/null || exit 1
        # ===========================================================

      else
        echo -e "  ${RED}Warning:${RESET} Functional run folder $run_dir not found."
      fi
    done

  # Process structural runs

    for run in $struct; do
      run_dir="${datapath}/${run}"
      if [[ -d "$run_dir" ]]; then
        seq_name=$(awk -F'[<>]' '/^##\$ACQ_protocol_name=/{getline; print $2; exit}' "$run_dir/acqp" 2>/dev/null || echo "UnknownSequence")
        clean_seq=$(echo "$seq_name" | tr -cd '[:alnum:]_-' | cut -c1-50)
        struct_path_analysed="${base_target}/${run}${clean_seq}"
        mkdir -p "$struct_path_analysed"
        echo -e "  ${CYAN}Created Structural:${RESET} $struct_path_analysed"

        # ===========================================================
        # Convert Bruker → NIfTI if missing, then copy reference file
        # ===========================================================
        pushd "$struct_path_analysed" >/dev/null || exit 1

        run_if_missing "anatomy.nii.gz" -- BRUKER_to_NIFTI "$datapath" "$run" "$datapath/$run/method"
        cp -f G1_cp.nii.gz anatomy.nii.gz 2>/dev/null || echo -e "${YELLOW}WARNING:${RESET} G1_cp.nii.gz not found for structural; continuing."

        popd >/dev/null || exit 1
        # ===========================================================

      else
        echo -e "  ${RED}Warning:${RESET} Structural run folder $run_dir not found."
      fi
    done


  echo
done


echo -e "\n${GREEN}Basic Data Processing folder structure created successfully.${RESET}\n"

printf "\n${BOLD_CYAN}=================================================================================================================================${RESET}\n"
printf "${BOLD_CYAN}                                                       Starting Data Pre Processing              ${RESET}\n"
printf "${BOLD_CYAN}=================================================================================================================================${RESET}\n\n"


# =====================================================================
# Interactive Function Table Builder and Execution Order Selector
# =====================================================================
# =====================================================================
# Function Table Builder and Manual Number Selection
# =====================================================================

# =====================================================================
# Function Table Builder and Manual Number Selection (Order Preserved)
# =====================================================================

build_function_table() {
  local repo_path="njainmpi/fMRI_analysis_pipeline"
  local files=(
    "toolbox_name.sh"
    "temporal_smoothing.sh"
    "missing_run.sh"
    "func_parameters_extraction.sh"
    "data_conversion.sh"
    "motion_correction.sh"
    "smoothing_using_fsl.sh"
    "temporal_snr_using_afni.sh"
    "temporal_snr_using_fsl.sh"
    "scm_from_coregsitered_functional_v1.sh"
  )

  FUNCTION_TABLE=()
  local index=1

  echo -e "${BOLD_CYAN}Fetching available functions from GitHub...${RESET}\n"

  for f in "${files[@]}"; do
    echo -e "${DIM_GRAY}→ Parsing:${RESET} $f"
    funcs=$(list_functions_in_file "$repo_path" "$f")
    [[ -z "$funcs" ]] && continue
    while IFS= read -r func; do
      [[ -z "$func" ]] && continue
      FUNCTION_TABLE+=("${index}|${f}|${func}")
      ((index++))
    done <<< "$funcs"
  done

  echo -e "\n${BOLD_CYAN}Available Functions:${RESET}\n"
  printf "${YELLOW}%-5s | %-40s | %-40s${RESET}\n" "No." "Source File" "Function Name"
  printf "${DIM_GRAY}%s${RESET}\n" "------+------------------------------------------+------------------------------------------"
  for entry in "${FUNCTION_TABLE[@]}"; do
    IFS='|' read -r idx file func <<< "$entry"
    printf "%-5s | %-40s | %-40s\n" "$idx" "$file" "$func"
  done
}


manual_function_selector() {
  echo -e "\n${BOLD_CYAN}Select which functions to execute (order preserved)${RESET}"
  echo -e "Enter function numbers (e.g. 5,2,4-6 or q to quit):"
  read -rp "> " selection
  case "$selection" in
    q|Q) echo "Aborted."; exit 0 ;;
  esac
  [[ -z "$selection" ]] && { echo -e "${RED}No selection made.${RESET}"; exit 1; }

  # Function to expand ranges but preserve order
  expand_in_order() {
    local input="$1" part a b n
    IFS=',' read -r -a parts <<< "$input"
    for part in "${parts[@]}"; do
      part="${part//[[:space:]]/}"
      if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
        a="${part%-*}"; b="${part#*-}"
        if ((a <= b)); then
          for ((n=a; n<=b; n++)); do echo "$n"; done
        else
          for ((n=a; n>=b; n--)); do echo "$n"; done
        fi
      elif [[ "$part" =~ ^[0-9]+$ ]]; then
        echo "$part"
      fi
    done
  }

  ORDERED_SELECTION=()
  while IFS= read -r num; do
    for entry in "${FUNCTION_TABLE[@]}"; do
      IFS='|' read -r idx file func <<< "$entry"
      if [[ "$num" == "$idx" ]]; then
        ORDERED_SELECTION+=("$func|$file|$idx")
      fi
    done
  done < <(expand_in_order "$selection")

  echo -e "\n${GREEN}You selected ${#ORDERED_SELECTION[@]} function(s) in this order:${RESET}\n"
  local order=1
  for entry in "${ORDERED_SELECTION[@]}"; do
    IFS='|' read -r func file idx <<< "$entry"
    printf "  %2d. %-40s (%s)\n" "$order" "$func" "$file"
    ((order++))
  done
  echo
}



build_function_table
manual_function_selector
