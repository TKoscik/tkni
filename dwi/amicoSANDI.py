#!/usr/local/tkni/pyvenv/amicoVENV/bin/python
import argparse
import amico
import numpy as np
import os
import shutil
import tempfile
from pathlib import Path

def run_sandi(args):
    # 1. Setup Directories
    dwi_path = Path(args.dwi).resolve()
    save_dir = Path(args.dir_save).resolve() if args.dir_save else dwi_path.parent
    save_dir.mkdir(parents=True, exist_ok=True)

    base_filename = dwi_path.name.replace('.nii.gz', '').replace('.nii', '')

    # 2. Initialize Scratch Space
    with tempfile.TemporaryDirectory(dir=args.dir_scratch) as tmpdir:
        tmp_path = Path(tmpdir)

        # Symlink input files
        tmp_dwi = tmp_path / dwi_path.name
        os.symlink(dwi_path, tmp_dwi)

        amico.setup()
        ae = amico.Evaluation(str(tmp_path), ".")

        # FIX: Explicitly set flipAxes to 3 boolean values
        #ae.set_config('flipAxes', [False, False, False])
        ae.set_config('doDirectionalAverage', True)

        # SANDI Scheme Generation (Converting ms to s)
        scheme_file = str(tmp_path / dwi_path.name.replace('.nii.gz', '.scheme'))
        amico.util.sandi2scheme(
            args.bval,
            args.bvec,
            args.delta / 1000.0,
            args.small_delta / 1000.0,
            args.TE / 1000.0,
            schemeFilename=scheme_file,
            bStep=100
        )

        # Load Data
        ae.load_data(dwi_path.name, scheme_file, mask_filename=args.mask, b0_thr=0)

        # Configure SANDI Model
        ae.set_model('SANDI')

        rs = np.array([float(x) for x in args.Rs.split(',')]) if args.Rs else np.linspace(1.0, 12.0, 5) * 1E-6
        d_in = np.array([float(x) for x in args.d_in.split(',')]) if args.d_in else np.linspace(0.25, 3.0, 5) * 1E-3
        d_isos = np.array([float(x) for x in args.d_isos.split(',')]) if args.d_isos else np.linspace(0.25, 3.0, 5) * 1E-3

        ae.model.set(d_is=args.d_is, Rs=rs, d_in=d_in, d_isos=d_isos)

        ae.generate_kernels(regenerate=True, ndirs=1)
        ae.load_kernels()

        ae.set_solver(lambda1=args.lambda1, lambda2=args.lambda2)
        ae.fit()
        ae.save_results()

        # 3. Flatten and Move Results
        amico_out_dir = tmp_path / "AMICO" / "SANDI"
        mapping = {
            "fit_fsoma.nii.gz": "SANDI-fsoma", "fit_fneurite.nii.gz": "SANDI-fneurite",
            "fit_fextra.nii.gz": "SANDI-fextra", "fit_Rsoma.nii.gz": "SANDI-Rsoma",
            "fit_Din.nii.gz": "SANDI-Din", "fit_De.nii.gz": "SANDI-De"
        }

        for src_name, target_suffix in mapping.items():
            src_file = amico_out_dir / src_name
            if src_file.exists():
                new_name = base_filename.replace("dwi", target_suffix) + ".nii.gz"
                shutil.move(str(src_file), str(save_dir / new_name))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AMICO SANDI CLI Wrapper")

    # Path Arguments
    parser.add_argument("--bval", required=True)
    parser.add_argument("--bvec", required=True)
    parser.add_argument("--dwi",  required=True)
    parser.add_argument("--mask", required=True)
    parser.add_argument("--dir-save", help="Final output directory (defaults to DWI folder)")
    parser.add_argument("--dir-scratch", default="/tmp")

    # Timing Parameters (Input in ms)
    parser.add_argument("--delta", type=float, default=44.2, help="Time between pulses (Δ) in milliseconds [ms]")
    parser.add_argument("--small_delta", type=float, default=25.8, help="Pulse duration (δ) in milliseconds [ms]")
    parser.add_argument("--TE", type=float, default=88.0, help="Echo Time in milliseconds [ms]")

    # SANDI Model Parameters
    parser.add_argument("--d_is", type=float, default=3.0E-3)
    parser.add_argument("--Rs", type=str)
    parser.add_argument("--d_in", type=str)
    parser.add_argument("--d_isos", type=str)

    # Solver Parameters
    parser.add_argument("--lambda1", type=float, default=0.0)
    parser.add_argument("--lambda2", type=float, default=5e-3)

    args = parser.parse_args()
    run_sandi(args)
