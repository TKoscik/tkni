rm(list=ls())
gc()

echo_spacing <- 0.0023
turbo_factor <- 5
echo_train_length <- echo_spacing * turbo_factor
readout_gap <- 0.9
TR <- 4.5

repetition_time <- 0.0574
flip_angle <- 4
inversion_time <- 0.11
readout_t <- c(0.110, 1.010, 1.910, 2.810, 3.710)
readout_duration <- 0.0023

ET <- exp(-readout_gap/T1)
ETstar <- exp(-(echo_spacing * turbo_factor)/T1)
ETR <- exp(-TR/T1)

Mn <- ((M0/ETstar) - ((ET * M0)/ETstar) - (M0star/ETstar) + M0star) / (1-(ET/ETstar))





# FUNCTIONS
relax_T2 <- function(Mz, TE_T2prep, T2) { Mx * exp(-TE_T2prep / T2) }
relax_T1 <- function(M0, Mz, dt, T1) { M0 - (M0 - Mz) * exp(-dt / T1) }


dt_m1m2 <- 0.1097
dt_m0m1 <- readout_gap - echo_train_length - dt_m1m2
dt_m2m3 <- dt_m6m7 <- dt_m8m9 <- dt_m10m11 <- dt_m12m13 <- echo_train_length
dt_m2m6 <- readout_gap
dt_m4m5 <- 0.128
dt_m5m6 <- 0.1 - 0.00645
dt_m3m4 <- dt_m2m6 - dt_m2m3 - dt_m4m5 - dt_m5m6
dt_m7m8 <- dt_m9m10 <- dt_m11m12 <- readout_gap - echo_train_length

total_event_duration <- dt_m0m1 + dt_m1m2 + dt_m2m3 + dt_m3m4 + dt_m4m5 + dt_m5m6 + dt_m6m7 + dt_m7m8 + dt_m8m9 + dt_m9m10 + dt_m10m11 + dt_m11m12 + dt_m12m13;
dt_m13end = max(TR - total_event_duration, 0);

M1 <- relax_T1(1, 1, dt_m0m1, )


#################

FA <- 4 #* pi / 180
TR <- 4.5
TRO <- 0.9
NTR <- 5
TE <- rep(0.0115,5)
#TE <- c(0.110, 1.010, 1.910, 2.810, 3.710)
#Mobs <- c(237, 447, 678, 977, 1062)
Mobs <- c(286, 444, 375, 711, 858)



















OPT.FCN <- function(INPUT, ...) {
  M0 <- INPUT[1]
  T1 <- INPUT[2]
  #print(sprintf("M0: %0.05g; T1: %0.05g", M0, T1))
  MA <- M0 - (M0 - Mobs) * exp(-(TE/T1))
  MRATIO <- (1 - exp(-(TR/T1))) / (1-(cos(FA)*exp(-(TR/T1))))
  T1star <- MRATIO * T1
  M0star <- MRATIO * M0
  MB <- M0star - (M0star - Mobs) * exp(-(TE/T1star))
  #print(MA)
  #print(MB)
  sum((MA-MB)^2)
}

OPT.FCN <- function(INPUT, ...) {
  M0 <- INPUT[1]
  T1 <- INPUT[2]
  print(sprintf("M0: %0.05g; T1: %0.05g", M0, T1))
  E1 <- exp(-(TE/T1))
  ER <- exp(-(TR/T1))
  MR <- ((1-ER)/(1-cos(FA)*ER))
  T1star <- T1*((1-ER)/(1-cos(FA)*ER))
  ERstar <- exp(-(TE/T1star))
  Mp <- ((MR*M0)-(ERstar*MR*M0)-(M0)+(E1*M0))/(E1-ERstar)
  print(Mp)
  sum((Mobs-Mp)^2)
}

OPT.OUT <- optim(c(Mobs[length(Mobs)],1.300), OPT.FCN)
OPT.OUT
T1 <- OPT.OUT$par[2]
#T2=-(0.9)/(log(Mobs[1]/Mobs[2]))
print(sprintf("T1: %0.05g; T2: %0.05g", T1, T2))

TURBO <- 5
TE <- 0.0023
DT <- TE * TURBO
FA <- 4
TR <- 4.5 
T2PREP <- 0.1097

OPT.FCN <- function(INPUT, ...) {
  print(INPUT)
  M0 <- INPUT[1]
  T1 <- INPUT[2]
  M0star <- M0 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  T1star <- T1 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  M06 <- Mobs[2]
  M07 <- M0star-(M0star-M06)^exp(-(DT/T1star))
  M08p <- M0-(M0-M07)^exp(-(DT/T1))
  
  M08 <- Mobs[3]
  M09 <- M0star-(M0star-M08)^exp(-(DT/T1star))
  M10p <- M0-(M0-M09)^exp(-(DT/T1))
  
  M10 <- Mobs[4]
  M11 <- M0star-(M0star-M10)^exp(-(DT/T1star))
  M12p <- M0-(M0-M11)^exp(-(DT/T1))
  
  M12 <- Mobs[5]
  M13 <- M0star-(M0star-M12)^exp(-(DT/T1star))
  M01p <- M0-(M0-M13)^exp(-(DT/T1))
  
  T2 <<- -T2PREP / log(Mobs[1]/M01p)
  #print(M01p)
  print(sum((Mobs[3:5] - c(M08p, M10p, M12p))^2))
  sum((Mobs[3:5] - c(M08p, M10p, M12p))^2)
}
## wrong DTs below... need to be readout time and readout gap minus readout time

DTread <- turbo_factor * readout_duration
DTgap <- readout_gap - DTread
DTinv <- 0.1-0.00645

TR <- 4.5
FA <- 4
TURBO <- 5
ECHO_SPACING <- 0.0023
RO_DUR <- TURBO * ECHO_SPACING 
RO_GAP <- 0.9 - RO_DUR
DT <- c(RO_GAP - RO_DUR - 0.1097, #M0->M1
        0.1097, # M1->M2
        RO_DUR, # M2->M3
        0.9-RO_DUR-0.0128-0.1+0.00645, # M3->M4
        0.0128, # M4->M5
        0.1-0.00645, # M5->M6
        RO_DUR, # M6->M7
        RO_GAP, # M7->M8
        RO_DUR, # M8->M9
        RO_GAP, # M9->M10
        RO_DUR, # M10->M11
        RO_GAP, # M11->M12
        RO_DUR) # M12->M13
DT <- c(DT, max(TR-sum(DT),0))


OPT.FCN <- function(INPUT, ...) {
  T1 <- INPUT[1]
  T2 <- INPUT[2]
  M0 <- INPUT[3]
  
  M0star <- M0 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  T1star <- T1 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  
  A <- B <- C <- D <- E <- numeric(13) * NA
  # predictions based on M2
  A[3] <- M0star-(M0star-Mobs[1])^exp(-(DT[3]/T1star))
  A[4] <- M0-(M0-A[3])^exp(-(DT[4]/T1))
  A[5] <- -A[4]
  A[6] <- M0-(M0-A[5])^exp(-(DT[6]/T1))
  A[7] <- M0star-(M0star-A[6])^exp(-(DT[7]/T1star))
  A[8] <- M0-(M0-A[7])^exp(-(DT[8]/T1))
  A[9] <- M0star-(M0star-A[8])^exp(-(DT[9]/T1star))
  A[10] <- M0-(M0-A[9])^exp(-(DT[10]/T1))
  A[11] <- M0star-(M0star-A[10])^exp(-(DT[11]/T1star))
  A[12] <- M0-(M0-A[11])^exp(-(DT[12]/T1))
  A[13] <- M0star-(M0star-A[12])^exp(-(DT[13]/T1star))
  A[1] <- M0-(M0-A[13])^exp(-(sum(c(DT[1],DT[14]))/T1))
  A[2] <- (M0-(M0-A[1])^exp(-(DT[2]/T1)))*exp(-DT[2]/T2)
  
  # Predictions based on M6
  B[7] <- M0star-(M0star-Mobs[2])^exp(-(DT[7]/T1star))
  B[8] <- M0-(M0-B[7])^exp(-(DT[8]/T1))
  B[9] <- M0star-(M0star-B[8])^exp(-(DT[9]/T1star))
  B[10] <- M0-(M0-B[9])^exp(-(DT[10]/T1))
  B[11] <- M0star-(M0star-B[10])^exp(-(DT[11]/T1star))
  B[12] <- M0-(M0-B[11])^exp(-(DT[12]/T1))
  B[13] <- M0star-(M0star-B[12])^exp(-(DT[13]/T1star))
  B[1] <- M0-(M0-B[13])^exp(-(sum(c(DT[1],DT[14]))/T1))
  B[2] <- (M0-(M0-B[1])^exp(-(DT[2]/T1)))*exp(-DT[2]/T2)
  B[3] <- M0star-(M0star-B[2])^exp(-(DT[3]/T1star))
  B[4] <- M0-(M0-B[3])^exp(-(DT[4]/T1))
  B[5] <- -B[4]
  B[6] <- M0-(M0-B[5])^exp(-(DT[6]/T1))
  B[7] <- M0star-(M0star-B[6])^exp(-(DT[7]/T1star))
  
  # Predictions based on M8
  C[9] <- M0star-(M0star-Mobs[3])^exp(-(DT[9]/T1star))
  C[10] <- M0-(M0-C[9])^exp(-(DT[10]/T1))
  C[11] <- M0star-(M0star-C[10])^exp(-(DT[11]/T1star))
  C[12] <- M0-(M0-C[11])^exp(-(DT[12]/T1))
  C[13] <- M0star-(M0star-C[12])^exp(-(DT[13]/T1star))
  C[1] <- M0-(M0-C[13])^exp(-(sum(c(DT[1],DT[14]))/T1))
  C[2] <- (M0-(M0-C[1])^exp(-(DT[2]/T1)))*exp(-DT[2]/T2)
  C[3] <- M0star-(M0star-C[2])^exp(-(DT[3]/T1star))
  C[4] <- M0-(M0-C[3])^exp(-(DT[4]/T1))
  C[5] <- -C[4]
  C[6] <- M0-(M0-C[5])^exp(-(DT[6]/T1))
  C[7] <- M0star-(M0star-C[6])^exp(-(DT[7]/T1star))
  C[8] <- M0-(M0-C[7])^exp(-(DT[8]/T1))
  C[9] <- M0star-(M0star-C[8])^exp(-(DT[9]/T1star))
  
  # Predictions based on M10
  D[11] <- M0star-(M0star-Mobs[4])^exp(-(DT[11]/T1star))
  D[12] <- M0-(M0-D[11])^exp(-(DT[12]/T1))
  D[13] <- M0star-(M0star-D[12])^exp(-(DT[13]/T1star))
  D[1] <- M0-(M0-D[13])^exp(-(sum(c(DT[1],DT[14]))/T1))
  D[2] <- (M0-(M0-D[1])^exp(-(DT[2]/T1)))*exp(-DT[2]/T2)
  D[3] <- M0star-(M0star-D[2])^exp(-(DT[3]/T1star))
  D[4] <- M0-(M0-D[3])^exp(-(DT[4]/T1))
  D[5] <- -D[4]
  D[6] <- M0-(M0-D[5])^exp(-(DT[6]/T1))
  D[7] <- M0star-(M0star-D[6])^exp(-(DT[7]/T1star))
  D[8] <- M0-(M0-D[7])^exp(-(DT[8]/T1))
  D[9] <- M0star-(M0star-D[8])^exp(-(DT[9]/T1star))
  D[10] <- M0-(M0-D[9])^exp(-(DT[10]/T1))
  D[11] <- M0star-(M0star-D[10])^exp(-(DT[11]/T1star))
  
  #Predictions based on M12
  E[13] <- M0star-(M0star-Mobs[5])^exp(-(DT[13]/T1star))
  E[1] <- M0-(M0-E[13])^exp(-(sum(c(DT[1],DT[14]))/T1))
  E[2] <- (M0-(M0-E[1])^exp(-(DT[2]/T1)))*exp(-DT[2]/T2)
  E[3] <- M0star-(M0star-E[2])^exp(-(DT[3]/T1star))
  E[4] <- M0-(M0-E[3])^exp(-(DT[4]/T1))
  E[5] <- -E[4]
  E[6] <- M0-(M0-E[5])^exp(-(DT[6]/T1))
  E[7] <- M0star-(M0star-E[6])^exp(-(DT[7]/T1star))
  E[8] <- M0-(M0-E[7])^exp(-(DT[8]/T1))
  E[9] <- M0star-(M0star-E[8])^exp(-(DT[9]/T1star))
  E[10] <- M0-(M0-E[9])^exp(-(DT[10]/T1))
  E[11] <- M0star-(M0star-E[10])^exp(-(DT[11]/T1star))
  E[12] <- M0-(M0-E[11])^exp(-(DT[12]/T1))
  E[13] <- M0star-(M0star-E[12])^exp(-(DT[13]/T1star))
  
  Mpred <- c((Mobs[1] - c(A[2], B[2], C[2], D[2], E[2]))^2,
             (Mobs[2] - c(A[6], B[6], C[6], D[6], E[6]))^2,
             (Mobs[3] - c(A[8], B[8], C[8], D[8], E[8]))^2,
             (Mobs[4] - c(A[10], B[10], C[10], D[10], E[10]))^2,
             (Mobs[5] - c(A[12], B[12], C[12], D[12], E[12]))^2)
  print(sum(is.na(Mpred)))
  sum(Mpred, na.rm=T)
}

M0.init <- max(Mobs)* (1 - cos(FA) * exp(-TR/T1)) / (1-exp(-TR/T1)) + 1
INPUT <- c(1331, 868, M0.init)
OPT.OUT <- optim(INPUT, OPT.FCN)
OPT.OUT$par
T1 <- OPT.OUT$par[2]
#T2=-(0.9)/(log(Mobs[1]/Mobs[2]))
print(sprintf("T1: %0.05g; T2: %0.05g", T1, T2))









M04 <- M0-(M0-M03)^exp(-(DT/T1))
M05 <- -M04
M06 <- M0-(M0-M05)^exp(-(DT/T1))
M08 <- M0-(M0-M07)^exp(-(DT/T1))
M10 <- M0-(M0-M09)^exp(-(DT/T1))
M12 <- M0-(M0-M11)^exp(-(DT/T1))
M01 <- M0-(M0-M13)^exp(-(DT/T1))



M03 <- M0star-(M0star-M02)^exp(-(DT/T1star))
M07 <- M0star-(M0star-M06)^exp(-(DT/T1star))
M09 <- M0star-(M0star-M08)^exp(-(DT/T1star))
M11 <- M0star-(M0star-M10)^exp(-(DT/T1star))
M13 <- M0star-(M0star-M12)^exp(-(DT/T1star))

T2 <- -T2PREP / ln(M01/M02)

(Mobs are M02, M06, M08, M10, M12)



# Estimate M02
Msub1 <- function(DT,T1,M0,Mz) {
  ET <- exp(-DT/T1)
  Mzz <- (Mz - M0 * (1 - ET))/ ET
  return(Mzz)
}
Madd1 <- function(DT,T1,M0,Mz) {
  ET <- exp(-DT/T1)
  Mzz <- M0 - (M0 - Mz) * ET
  return(Mzz)
}

M0 <- Mobs[length(Mobs)]
T1 <- 1.300

OPT.FCN <- function(INPUT, ...) {
  T1 <- INPUT[1]
  M0 <- INPUT[2]
  M0star <- M0 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  T1star <- T1 * (1-exp(-TR/T1)) / (1 - cos(FA) * exp(-TR/T1))
  
  M06p <- (c(Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Mobs[3])),
             Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Mobs[4])))),
             Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Mobs[5]))))))) - Mobs[2])^2
  
  M08p <- (c(Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Mobs[2])),
             Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Mobs[4])))),
             Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Mobs[5]))))))) - Mobs[3])^2
  
  M10p <- (c(Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Mobs[2])),
             Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Mobs[3])))),
             Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Msub1(DT,T1star,M0star,Msub1(DT,T1,M0,Mobs[5]))))))) - Mobs[4])^2
  
  M12p <- (c(Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Mobs[2])),
             Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Mobs[3])))),
             Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Madd1(DT,T1star,M0star,Madd1(DT,T1,M0,Mobs[4]))))))) - Mobs[5])^2
  M01p <<- Madd1(DT, T1, M0, Madd1(DT, T1star, M0star, Mobs[5]))
  print(sum(M06p, M08p, M10p, M12p))
  sum(M06p, M08p, M10p, M12p)
}

OPT.OUT <- optim(c(Mobs[length(Mobs)],1.300), OPT.FCN)
OPT.OUT <- optim(OPT.OUT$par, OPT.FCN)
OPT.OUT

M0vals <- seq(1,1000,0.001)
T1vals <- seq(0.5,2,0.001)
MANOPT <- matrix(0,nrow=0, ncol=3)
for (i in 1:length(M0vals)) {
  for (j in 1:length(T1vals)) {
    TX <- c(M0vals[i], T1vals[j], OPT.FCN(c(T1vals[j], M0vals[i])))
    MANOPT <- cbind(MANOPT, TX)
  }
}

T1 <- OPT.OUT$par[1]
T2=-(0.11)/(log(Mobs[2]/M01p))
print(sprintf("T1: %0.05g; T2: %0.05g", T1, T2))
