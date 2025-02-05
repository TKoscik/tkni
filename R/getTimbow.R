args <- commandArgs()

n.colors <- 11
start.hue <- "#FF0000"
saturation <- 100
luminosity.lo <- 35
luminosity.hi <- 65
cycles <- 5/6
direction <- "increasing"

for (i in 1:length(args)) {
  if (args[i] %in% c("n", "n.colors", "colors", "cols")) { n.colors <- as.numeric(args[i+1]) }
  if (args[i] %in% c("hue", "start.hue", "start")) { start.hue <- args[i+1] }
  if (args[i] %in% c("sat", "saturation", "colorfulness")) { saturation <- as.numeric(args[i+1]) }
  if (args[i] %in% c("lo", "lum.lo", "luminosity.lo")) { luminosity.lo <- as.numeric(args[i+1]) }
  if (args[i] %in% c("hi", "lum.hi", "luminosity.hi")) { luminosity.hi <- as.numeric(args[i+1]) }
  if (args[i] %in% c("arc", "cyc", "cycles", "n.cycles")) { cycles <- eval(parse(text=args[i+1])) }
  if (args[i] %in% c("dir", "direction" )) { direction <- args[i+1] }
}

library(timbow)
palette <- timbow(n.colors=n.colors,
                  start.hue = start.hue,
                  colorfulness = saturation,
                  luminosity.limits = c(luminosity.lo, luminosity.hi),
                  hue.direction = direction,
                  n.cycles = cycles)
cat(palette)
