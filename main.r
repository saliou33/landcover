# 1. SETUP

# 1.1 PACKAGES

libs <- c(
  "terra",
  "giscoR",
  "sf",
  "tidyverse",
  "ggtern",
  "elevatr",
  "png",
  "rayshader",
  "magick"
)

installed_libraries <- libs %in% rownames(
  installed.packages()
)

if(any(installed_libraries == F)){
  install.packages(
    libs[!installed_libraries]
  )
}

invisible(
  lapply(
    libs, library, character.only = T
  )
)

# 1.2 CONSTANTS 

COUNTRY_CRS <- 32628

COUNTRY_CODE <- "SN"

CRS_LAMBERT <- "+proj=utm +zone=28 +datum=WGS84 +units=m +no_defs"

COUNTRY_RASTER_PATTERN <- "20240101.tif$"

REGIONS <- list.files(path = file.path(getwd(), "regions"), pattern = ".shp", full.names = TRUE)

# ESRI_RASTER_URLS <- c(
#   "https://lulctimeseries.blob.core.windows.net/lulctimeseriesv003/lc2023/28P_20230101-20240101.tif"
#   # Add additional URLs if needed
# )

# 1.3 DOWNLOAD ESRI LAND COVER

# for(url in esri_raster_urls){
#   download.file(url = url, destfile = basename(url), mode = "wb")
# }


# 1.4 HELPER FUNCTION TO GET COUNTRY BORDERS 

get_country_borders_tr <- function() {
  main_path <- getwd()
  country_borders <- geodata::gadm(
    country = COUNTRY_CODE,
    level = 1,
    path = main_path
  ) |>
    sf::st_as_sf()
  
  return(country_borders)
}

country_borders <- get_country_borders_tr()

unique(
  country_borders$NAME_1
)

# 1.5 DOWNLOAD HDRI FILE USED FOR SCENE LIGHTING

u <- "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/air_museum_playground_4k.hdr"
hdri_file <- basename(u)

# download.file(
#   url = u,
#   destfile = hdri_file,
#   mode = "wb"
# )


# 1.5 LOAD RASTER

raster_files <- list.files(
  path = getwd(),
  pattern = COUNTRY_RASTER_PATTERN,
  full.names = T
)

########## MAIN LOOP ###########

for(region_path in REGIONS) {
  
  # 1. CREATE 
  region_name = sapply(strsplit(region_path, "/"), tail, 1)
  region_data = st_read(region_path, quiet=T)
  country_sf <- st_transform(region_data, crs = COUNTRY_CRS)

  if(file.exists(file.path(getwd(), paste0(region_name, "_land_cover_vrt.vrt")))){
    print(region_name)
    next
  }
  
  # 3 LOAD TILES
  
  crs <- paste0("EPSG:", COUNTRY_CRS)
  
  for(raster in raster_files){
    rasters <- terra::rast(raster)
    
    country <- country_sf |>
      sf::st_transform(
        crs = terra::crs(
          rasters
        )
      )
    
    land_cover <- terra::crop(
      rasters,
      terra::vect(
        country
      ),
      snap = "in",
      mask = T
    ) |>
      terra::aggregate(
        fact = 5,
        fun = "modal"
      ) |>
      terra::project(crs)
    
    terra::writeRaster(
      land_cover,
      paste0(
        raster,
        "_",
        region_name,
        ".tif"
      )
    )
  }
  
  # 4 LOAD VIRTUAL LAYER
  
  r_list <- list.files(
    path = getwd(),
    pattern = paste0("_", region_name),
    full.names = T
  )
  
  land_cover_vrt <- terra::vrt(
    r_list, 
    paste0(region_name, "_land_cover_vrt.vrt"),
    overwrite = T
  )
  
  # 5 FETCH ORIGINAL COLORS
  
  ras <- terra::rast(
    raster_files[[1]]
  )
  
  raster_color_table <- do.call(
    data.frame,
    terra::coltab(ras)
  )
  
  head(raster_color_table)
  
  hex_code <- ggtern::rgb2hex(
    r = raster_color_table[,2],
    g = raster_color_table[,3],
    b = raster_color_table[,4]
  )
  
  # 6 ASSIGN COLORS TO RASTER
  
  cols <- hex_code[c(2:3, 5:6, 8:12)]
  
  from <- c(1:2, 4:5, 7:11)
  to <- t(col2rgb(cols))
  land_cover_vrt <- na.omit(land_cover_vrt)
  
  land_cover_region <- terra::subst(
    land_cover_vrt,
    from = from,
    to = to,
    names = cols
  )
  
  terra::plotRGB(land_cover_region)
  
  # 7 DIGITAL ELEVATION MODEL
  
  elev <- elevatr::get_elev_raster(
    locations = country_sf,
    z = 9, clip = "locations",
  )
  
  crs_lambert <- CRS_LAMBERT
  
  land_cover_region_resampled <- terra::resample(
    x = land_cover_region,
    y = terra::rast(elev),
    method = "near"
  ) |>
    
    terra::project(crs_lambert)
  terra::plotRGB(land_cover_region_resampled)
  
  img_file <- paste0("land_cover_", region_name, ".png")
  
  terra::writeRaster(
    land_cover_region_resampled,
    img_file,
    overwrite = T,
    NAflag = 255
  )
  
  img <- png::readPNG(img_file)
  
  
  # 8. RENDER SCENE
  #----------------
  
  elev_lambert <- elev |>
    terra::rast() |>
    terra::project(crs_lambert)
  
  elmat <- rayshader::raster_to_matrix(
    elev_lambert
  )
  
  h <- nrow(elev_lambert)
  w <- ncol(elev_lambert)
  
  elmat |>
    rayshader::height_shade(
      texture = colorRampPalette(
        cols[9]
      )(256)
    ) |>
    rayshader::add_overlay(
      img,
      alphalayer = 1
    ) |>
    rayshader::plot_3d(
      elmat,
      zscale = 12,
      solid = F,
      shadow = T,
      shadow_darkness = 1,
      background = "white",
      windowsize = c(
        w / 5, h / 5
      ),
      zoom = .5,
      phi = 85,
      theta = 0
    )
  
  rayshader::render_camera(
    zoom = .58
  )
  
  # 9. RENDER OBJECT
  #-----------------
  
  filename <- paste0("3d_land_cover_", region_name, ".png")
  
  rayshader::render_highquality(
    filename = filename,
    preview = T,
    light = F,
    environment_light = hdri_file,
    intensity_env = 1,
    rotate_env = 90,
    interactive = F,
    parallel = T,
    width = w * 1.5,
    height = h * 1.5
  )
  dev.off()
  # 10. PUT EVERYTHING TOGETHER
  
  # c(
  #   "#419bdf", "#397d49", "#7a87c6",
  #   "#e49635", "#c4281b", "#a59b8f",
  #   "#a8ebff", "#616161", "#e3e2c3"
  # )
  # 
  # legend_name <- paste0("land_cover_legend_", region_name, ".png")
  # png(legend_name)
  # par(family = "mono")
  # 
  # plot(
  #   NULL,
  #   xaxt = "n",
  #   yaxt = "n",
  #   bty = "n",
  #   ylab = "",
  #   xlab = "",
  #   xlim = 0:1,
  #   ylim = 0:1,
  #   xaxs = "i",
  #   yaxs = "i"
  # )
  # legend(
  #   "center",
  #   legend = c(
  #     "Water",
  #     "Trees",
  #     "Crops",
  #     "Built area",
  #     "Rangeland"
  #   ),
  #   pch = 15,
  #   cex = 2,
  #   pt.cex = 1,
  #   bty = "n",
  #   col = c(cols[c(1:2, 4:5, 9)]),
  #   fill = c(cols[c(1:2, 4:5, 9)]),
  #   border = "grey20"
  # )
  # dev.off()
  # 
  # # filename <- "land-cover-bih-3d-b.png"
  # 
  # lc_img <- magick::image_read(
  #   filename
  # )
  # 
  # my_legend <- magick::image_read(
  #   legend_name
  # )
  # 
  # my_legend_scaled <- magick::image_scale(
  #   magick::image_background(
  #     my_legend, "none"
  #   ), 1000
  # )
  # 
  # p <- magick::image_composite(
  #   magick::image_scale(
  #     lc_img, "x5000" 
  #   ),
  #   my_legend_scaled,
  #   gravity = "southwest",
  #   offset = "+150+0"
  # )
  # 
  # # Add the title on the image
  # p <- magick::image_annotate(
  #   p,
  #   text = toupper(region_name),
  #   font = "sans",
  #   size = 200, 
  #   color = "grey20", 
  #   location = "+150+150", 
  #   gravity = "northwest" 
  # )
  # 
  # magick::image_write(
  #   p, paste0("3d_final_", region_name, "_land_cover.png")
  # )
  }


