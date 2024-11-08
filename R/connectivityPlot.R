
args <- commandArgs(trailingOnly = TRUE)

suppressMessages(suppressWarnings(library(reshape2)))
suppressMessages(suppressWarnings(library(ggplot2)))
suppressMessages(suppressWarnings(library(tools)))
suppressMessages(suppressWarnings(library(timbow)))

dx <- args[1]

# get save directory
dir.save <- dirname(dx)
bname <- file_path_sans_ext(basename(dx))

# load connectivity data and melt
dx <- as.matrix(read.csv(dx, header = F))
dx <- melt(dx)
dx$Var2 <- factor(dx$Var2, levels=rev(levels(dx$Var2)))

dx$value[dx$value==0] <- NA
dx$value <- log(dx$value)
clrs <- timbow(7, luminosity.limits = c(15,95), start.hue = "#0000FF", n.cycles = 7/12, show.plot = F)
the.plot <- 
  ggplot(data=dx, aes(x=Var1, y=Var2, fill=value)) +
  theme_void() +
  scale_fill_gradientn(colours = rev(clrs), na.value = "#FFFFFF", name= "log") +
  coord_equal() +
  geom_raster() + 
  theme(plot.background = element_rect(fill="#FFFFFF", color="transparent"),
        legend.text = element_text(size=8),
        plot.title = element_text(size=10),
        axis.title = element_blank())

options(bitmapType = 'cairo', device = 'png')
ggsave(filename=paste0(bname, ".png"), path=dir.save,
       plot=the.plot, device="png", width=7.5, height=7.5, dpi=320)


