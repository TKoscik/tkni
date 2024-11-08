PI=evanderplas
PROJECT=unitcall
DIR_PROJECT=/data/x/projects/evanderplas/unitcall

PIPE=tkni
TKNIPIPES="${TKNIPATH}/pipelines"
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}

REDO_DICOM="false"
REDO_AINIT="false"
REDO_FSSYNTH="false"
REDO_MALF="false"
REDO_TSEG="false"
REDO_FUNK="false"
REDO_DPREP="false"
REDO_REFINE="false"
REDO_DSCALE="false"
REDO_DTRACT="false"
REDO_FCON="false"
REDO_DCON="false"
REDO_SUMMARY="false"

PIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f participant_id))
SIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f session_id))
AIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f assessment_id))
N=${#PIDLS[@]}

PIPE=tkni
FLOW=MALF
MOD=T1w
ATLAS_NAME="HCPYAX"
ATLAS_REF="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz"
ATLAS_LABEL=("DKT" "wmparc" "hcpmmp1" "cerebellum")
DIR_ANAT=${DIR_PROJECT}/derivatives/${PIPE}/anat
DIR_REG=${DIR_ANAT}/reg_${ATLAS_NAME}
for (( idx=1; idx<${N}; idx++ )); do
  IDPFX=sub-${PIDLS[${idx}]}_ses-${SIDLS[${idx}]}_aid-${AIDLS[${idx}]}
  IDDIR=sub-${PIDLS[${idx}]}/ses-${SIDLS[${idx}]}
  DIR_XFM=${DIR_PIPE}/xfm/${IDDIR}
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}

  if [[ -f ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt ]]; then
   RMD=${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}.Rmd
   if [[ ! -f ${RMD} ]]; then
    echo -e '---\ntitle: "&nbsp;"\noutput: html_document\n---\n' > ${RMD}
    echo '```{r setup, include=FALSE}' >> ${RMD}
    echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
    echo -e '```\n' >> ${RMD}
    echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
    echo 'knitr::include_graphics("'${TKNIPATH}'/TK_BRAINLab_logo.png")' >> ${RMD}
    echo -e '```\n' >> ${RMD}
    echo '```{r, echo=FALSE}' >> ${RMD}
    echo 'library(DT)' >> ${RMD}
    echo 'library(downloadthis)' >> ${RMD}
    echo "create_dt <- function(x){" >> ${RMD}
    echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
    echo "    options=list(dom='Blfrtip'," >> ${RMD}
    echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
    echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
    echo -e '```\n' >> ${RMD}

    echo '## '${PIPE}${FLOW}': Multi-Atlas Normalization and Label Fusion' >> ${RMD}
    echo -e '\n---\n' >> ${RMD}

    # output Project related information -------------------------------------------
    echo 'PI: **'${PI}'**\' >> ${RMD}
    echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
    echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
    echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
    echo '' >> ${RMD}

    echo '### Multi-Atlas Normalization' >> ${RMD}
    echo '#### Normalized Participant Image' >> ${RMD}
    TNII=${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.nii.gz
    TPNG=${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo '#### Atlas Target Image' >> ${RMD}
    TPNG="${ATLAS_REF//\.nii\.gz}.png"
    if [[ ! -f ${TPNG} ]]; then make3Dpng --bg ${ATLAS_REF}; fi
    echo '!['${ATLAS_REF}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo '#### Normalization Overlay' >> ${RMD}
    TPNG=${DIR_XFM}/${IDPFX}_from-native_to-${ATLAS_NAME}_overlay.png
    if [[ -f "${TPNG}" ]]; then
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    else
      echo '*PNG not found*\' >> ${RMD}
    fi

    if [[ ${NO_JAC} == "false" ]]; then
      echo '### Jacobian Determinants' >> ${RMD}
      DIR_JAC=${DIR_ANAT}/outcomes/jacobian_from-native_to-${ATLAS_NAME}
      TNII=${DIR_JAC}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn_jacobian.nii.gz
      TPNG=${DIR_JAC}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn_jacobian.png
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi

    echo '### Labels {.tabset}' >> ${RMD}
    for (( i=0; i<${#ATLAS_LABEL[@]}; i++ )); do
      LAB=${ATLAS_LABEL[${i}]}
      TNII=${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz
      TPNG=${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.png
      TCSV=${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}_volume.tsv
      TJAC=${DIR_JAC}/${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}_jacobian.tsv
      echo '#### '${LAB} >> ${RMD}
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
      if [[ -f ${TCSV} ]]; then
        FNAME="${IDPFX}_label-${LAB}+${FLOW}_volume"
        echo '```{r}' >> ${RMD}
        EXT=${TCSV##*.}
        if [[ ${EXT} == "tsv" ]]; then
          echo 'data'${i}' <- read.csv("'${TCSV}'", sep="\t")' >> ${RMD}
        else
          echo 'data'${i}' <- read.csv("'${TCSV}'")' >> ${RMD}
        fi
        echo 'download_this(.data=data'${i}',' >> ${RMD}
        echo '  output_name = "'${FNAME}'",' >> ${RMD}
        echo '  output_extension = ".csv",' >> ${RMD}
        echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
        echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
        echo '```' >> ${RMD}
        echo '' >> ${RMD}
      fi
      if [[ -f ${TJAC} ]]; then
        FNAME="${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}_jacobian"
        echo '```{r}' >> ${RMD}
        EXT=${TJAC##*.}
        if [[ ${EXT} == "tsv" ]]; then
          echo 'JACdata'${i}' <- read.csv("'${TJAC}'", sep="\t")' >> ${RMD}
        else
          echo 'JACdata'${i}' <- read.csv("'${TJAC}'")' >> ${RMD}
        fi
        echo 'download_this(.data=JACdata'${i}',' >> ${RMD}
        echo '  output_name = "'${FNAME}'",' >> ${RMD}
        echo '  output_extension = ".csv",' >> ${RMD}
        echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
        echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
        echo '```' >> ${RMD}
        echo '' >> ${RMD}
      fi
    done

    ## knit RMD
    Rscript -e "rmarkdown::render('${RMD}')"
   fi
  fi
done
