#!/usr/local/tkni/pyvenv/amicoVENV/bin/python

import argparse
import amico
import numpy as np
import os
import shutil
import tempfile
from pathlib import Path

def run_noddi(args):
    # 1. Setup Directories
    dwi_path = Path(args.dwi).resolve()
    # Default dir-save to DWI folder if not provided
    save_dir = Path(args.dir_save).resolve() if args.dir_save else dwi_path.parent
    save_dir.mkdir(parents=True, exist_ok=True)

    base_filename = dwi_path.name.replace('.nii.gz', '').replace('.nii', '')

    # 2. Initialize Scratch Space
    with tempfile.TemporaryDirectory(dir=args.dir_scratch) as tmpdir:
        tmp_path = Path(tmpdir)

        # Symlink input files into scratch for AMICO local access
        tmp_dwi = tmp_path / dwi_path.name
        os.symlink(dwi_path, tmp_dwi)

        amico.setup()
        # Set study_path to scratch, subject to '.' to keep structure flat
        ae = amico.Evaluation(str(tmp_path), ".")

        # Scheme generation in scratch
        scheme_file = str(tmp_path / dwi_path.name.replace('.nii.gz', '.scheme'))
        amico.util.fsl2scheme(args.bval, args.bvec, scheme_file)

        # Load Data
        ae.load_data(dwi_path.name, scheme_file, mask_filename=args.mask, b0_thr=0)

        # Configure Model
        ae.set_model('NODDI')

        # Parse arrays or use specific defaults
        ic_vfs = np.array([float(x) for x in args.IC_VFs.split(',')]) if args.IC_VFs else np.linspace(0.1, 0.99, 12)
        ic_ods = np.array([float(x) for x in args.IC_ODs.split(',')]) if args.IC_ODs else np.hstack((np.array([0.03, 0.06]), np.linspace(0.09, 0.99, 10)))

        ae.model.set(
            dPar=args.dPar,
            dIso=args.dIso,
            isExvivo=args.isExvivo,
            IC_VFs=ic_vfs,
            IC_ODs=ic_ods
        )

        ae.generate_kernels(regenerate=True)
        ae.load_kernels()
        ae.fit()
        ae.save_results()

        # 3. Flatten and Move Results (No subfolders in save_dir)
        amico_out_dir = tmp_path / "AMICO" / "NODDI"

        mapping = {
            "fit_dir.nii.gz": "NODDI-dir",
            "fit_FWF.nii.gz": "NODDI-FWF",
            "fit_NDI.nii.gz": "NODDI-NDI",
            "fit_ODI.nii.gz": "NODDI-ODI"
        }

        for src_name, target_suffix in mapping.items():
            src_file = amico_out_dir / src_name
            if src_file.exists():
                new_name = base_filename.replace("dwi", target_suffix) + ".nii.gz"
                shutil.move(str(src_file), str(save_dir / new_name))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AMICO NODDI CLI Wrapper")

    # Path Arguments
    parser.add_argument("--bval", required=True)
    parser.add_argument("--bvec", required=True)
    parser.add_argument("--dwi",  required=True)
    parser.add_argument("--mask", required=True)
    parser.add_argument("--dir-save", help="Final output directory (defaults to DWI folder)")
    parser.add_argument("--dir-scratch", default="/tmp", help="Parent directory for temp scratch space")

    # NODDI Parameters
    parser.add_argument("--dPar", type=float, default=1.7E-3)
    parser.add_argument("--dIso", type=float, default=3.0E-3)
    parser.add_argument("--isExvivo", action="store_true")
    parser.add_argument("--IC_VFs", type=str, default="")
    parser.add_argument("--IC_ODs", type=str, default="")

    args = parser.parse_args()
    run_noddi(args)
