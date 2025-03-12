ASL pipeline
(PCASL only)

-is the pwi image the M0?

1. reorient image
2. motion correction
3. split into volumes (control and label pairs)
4. denoise
5. mean control image
6. FG mask - from mean control
7. bias correction
8. calculate M0 (mean control image)
9. brain mask
--pairwise - control/label pairs
10. calculate deltaM (control - labeled pairs)
11. calculate CBF
  (6000*lambda*deltaM*exp(-((gamma)/(t1blood))))/(2*alpha*M0*t1blood*(1-exp(-(tau)/(t1blood))))
  lambda = 0.9 mL/g, brain-blood partition coefficient
  tau =

