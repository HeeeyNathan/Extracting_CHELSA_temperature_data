# CHELSA V2 Temperature Data Download and Processing Script
# Purpose: Download CHELSA data using bulk download method and extract temperature values
# Author: Nathan Jay Baker
# Date: 04 August 2025
# This R code is free, intended to help the community, and comes with ABSOLUTELY NO WARRANTY.

# METHOD: Using CHELSA bulk download with envidatS3paths.txt file

# A envidatS3paths.txt file was downloaded from the CHELSA website: https://envicloud.wsl.ch/#/?bucket=https%3A%2F%2Fos.zhdk.cloud.switch.ch%2Fchelsav2%2F&prefix=%2F

# Load required packages
library(tidyverse)
library(raster)

# set working directory
# setwd("C:/Users/...") # add yours here

# ==============================================================================
# 1. DEFINE SAMPLING SITES
# ==============================================================================

# Your four sampling sites in Germany (coordiates in UTM)
sampling_sites <- data.frame(
  stream = c("Aubach", "Bieber", "Kinzig O3", "Kinzig W1"),
  site_code = c("Auba", "Bieb", "KiO3", "KiW1"),
  site_name = c("oh. Wiesthal", "oh. Rossbach", "uh. Rothenbergen", "Bulau"),
  UTM_E = c(9.42889356, 9.3051018, 9.10036763, 8.96570543), # Longitude
  UTM_N = c(50.0374896, 50.1617954, 50.1868858, 50.1315991), # Latitude
  Rechtswert = c(3530801.78, 3521876.92, 3507243.99, 3497623.98),
  Hochwert = c(5544665.62, 5558448.64, 5561199.75, 5555045.85),
  stringsAsFactors = FALSE
)

# ==============================================================================
# 2. DOWNLOAD CHELSA TEMPERATURE DATA
# ==============================================================================

# Read file paths from the text file
file_paths <- readLines("envidatS3paths.txt")

# Remove leading and trailing whitespace from each line
file_paths_clean <- trimws(file_paths)

# Filter for years 2000-2019 and temperature data using regex
# Updated pattern to match your requested years (2000-2019)
pattern <- "tas.*_(2000|200[1-9]|201[0-9])_"  # Matches 2000-2019 and contains 'tas'
file_paths_filtered <- file_paths_clean[grepl(pattern, file_paths_clean)]

# Remove any empty lines
file_paths_final <- file_paths_filtered[file_paths_filtered != ""]

# Display first few files to verify
head(file_paths_final, 5)

# Create CHELSA data directory
data_dir <- "CHELSA_data"

# Download files with robust error checking
downloaded_files <- c()
failed_downloads <- c()
download_errors <- 0
max_allowed_errors <- 1  # Stop after 1 error

for (i in 1:length(file_paths_final)) {
  path <- file_paths_final[i]

  # Extract the file name from the URL
  file_name <- basename(path)
  local_path <- file.path(data_dir, file_name)

  # Check if file already exists and is not empty
  if (file.exists(local_path)) {
    file_size <- file.info(local_path)$size
    if (!is.na(file_size) && file_size > 1000000) {  # File exists and is > 1MB
      cat("File already exists:", file_name, "(", round(file_size/1024/1024, 1), "MB )\n")
      downloaded_files <- c(downloaded_files, local_path)
      download_errors <- 0  # Reset error counter on success
      next
    } else {
      cat("File exists but appears corrupted, re-downloading:", file_name, "\n")
      file.remove(local_path)  # Remove corrupted file
    }
  }

  # Attempt to download the file
  cat("Downloading (", i, "/", length(file_paths_final), "):", file_name, "\n")

  # Get expected file size from server (if possible)
  expected_size <- NULL
  tryCatch({
    # Try to get content length from HTTP header
    con <- url(path, "rb")
    headers <- attr(con, "headers")
    close(con)
    if (!is.null(headers) && "content-length" %in% names(headers)) {
      expected_size <- as.numeric(headers[["content-length"]])
    }
  }, error = function(e) {
    # If we can't get expected size, we'll just check for reasonable size
  })

  # Download the file
  download_success <- FALSE
  tryCatch({
    download.file(path, destfile = local_path, method = "auto", mode = "wb")

    # Check if file was created and has reasonable size
    if (file.exists(local_path)) {
      downloaded_size <- file.info(local_path)$size

      # Validate file size
      if (is.na(downloaded_size) || downloaded_size < 1000000) {  # Less than 1MB is suspicious
        stop(paste("Downloaded file is too small:", downloaded_size, "bytes"))
      }

      # If we have expected size, check if they match (within 1% tolerance)
      if (!is.null(expected_size)) {
        size_difference <- abs(downloaded_size - expected_size) / expected_size
        if (size_difference > 0.01) {  # More than 1% difference
          stop(paste("File size mismatch. Expected:", expected_size,
                    "bytes, Downloaded:", downloaded_size, "bytes"))
        }
      }

      # Verify file is a valid TIFF (check magic number)
      con <- file(local_path, "rb")
      magic_bytes <- readBin(con, "raw", 4)
      close(con)

      # TIFF files start with either "II*\0" (little-endian) or "MM\0*" (big-endian)
      is_tiff <- identical(magic_bytes[1:2], as.raw(c(0x49, 0x49))) ||
                 identical(magic_bytes[1:2], as.raw(c(0x4D, 0x4D)))

      if (!is_tiff) {
        stop("Downloaded file is not a valid TIFF format")
      }

      cat("Successfully downloaded:", file_name,
          "(", round(downloaded_size/1024/1024, 1), "MB )\n")
      downloaded_files <- c(downloaded_files, local_path)
      download_success <- TRUE
      download_errors <- 0  # Reset error counter on success

    } else {
      stop("File was not created after download attempt")
    }

  }, error = function(e) {
    error_message <- paste("Error downloading", file_name, ":", e$message)
    cat(error_message, "\n")

    # Remove partially downloaded file if it exists
    if (file.exists(local_path)) {
      file.remove(local_path)
    }

    failed_downloads <- c(failed_downloads, file_name)
    download_errors <<- download_errors + 1

    # Check if we should stop due to too many errors
    if (download_errors >= max_allowed_errors) {
      cat("\n!!! CRITICAL ERROR !!!\n")
      cat("Too many consecutive download failures (", download_errors, ")\n")
      cat("This suggests a systematic problem (network, server, or authentication)\n")
      cat("Failed files:\n")
      for (failed_file in tail(failed_downloads, max_allowed_errors)) {
        cat("  -", failed_file, "\n")
      }
      cat("\nStopping download process to prevent further issues.\n")
      cat("Please check:\n")
      cat("1. Your internet connection\n")
      cat("2. The CHELSA server status\n")
      cat("3. The envidatS3paths.txt file format\n")
      cat("4. Available disk space\n")
      stop("Download process terminated due to multiple failures")
    }
  })

  # Small delay between downloads to be respectful to the server
  if (download_success) {
    Sys.sleep(0.5)  # 0.5 second delay
  }
}

# Final download summary
cat("Successfully downloaded:", length(downloaded_files), "files\n")
cat("Failed downloads:", length(failed_downloads), "files\n")

# ==============================================================================
# 3. PROCESS DOWNLOADED TEMPERATURE FILES
# ==============================================================================

# Function to extract year and month from filename
extract_date_from_filename <- function(filename) {
  # Expected format: CHELSA_tas_MM_YYYY_V.2.1.tif
  # Extract year and month using regex
  pattern <- "CHELSA_tas_(\\d{2})_(\\d{4})_"
  matches <- regmatches(filename, regexec(pattern, filename))

  if (length(matches[[1]]) >= 3) {
    month <- as.numeric(matches[[1]][2])
    year <- as.numeric(matches[[1]][3])
    return(list(year = year, month = month))
  } else {
    return(NULL)
  }
}

# Function to extract temperature values for all sites from a raster file
extract_temperature_for_sites <- function(raster_file, site_coordinates) {
  tryCatch({
    # Load raster
    temp_raster <- raster(raster_file)

    # Extract temperature values for all sites
    temp_values <- extract(temp_raster, site_coordinates[, c("UTM_E", "UTM_N")])

    # Convert from Kelvin*10 to Celsius (CHELSA uses Kelvin * 10)
    temp_celsius <- (temp_values * 0.1) - 273.15

    return(temp_celsius)
  }, error = function(e) {
    cat("Error processing raster file", basename(raster_file), ":", e$message, "\n")
    return(rep(NA, nrow(site_coordinates)))
  })
}

# Initialize results dataframe
results <- data.frame()

# Process each downloaded file
for (i in 1:length(downloaded_files)) {
  file_path <- downloaded_files[i]
  file_name <- basename(file_path)

  # Extract date information from filename
  date_info <- extract_date_from_filename(file_name)

  if (is.null(date_info)) {
    cat("Warning: Could not extract date from", file_name, "\n")
    next
  }

  # Extract temperature values for all sites
  temp_values <- extract_temperature_for_sites(file_path, sampling_sites)

  # Store results for each site
  for (j in 1:nrow(sampling_sites)) {
    result_row <- data.frame(
      stream = sampling_sites$stream[j],
      site_code = sampling_sites$site_code[j],
      site_name = sampling_sites$site_name[j],
      UTM_E = sampling_sites$UTM_E[j],
      UTM_N = sampling_sites$UTM_N[j],
      year = date_info$year,
      month = date_info$month,
      temperature_C = temp_values[j],
      stringsAsFactors = FALSE
    )
    results <- rbind(results, result_row)
  }
}

# ==============================================================================
# 4. SAVE RESULTS
# ==============================================================================

# Sort results by site, year, and month
results <- results |>
  arrange(site_code, year, month)

# Create output filename with timestamp
output_filename <- paste0("CHELSA_temperature_data_",
                         format(Sys.Date(), "%Y%m%d"), ".csv")

# Save results
write_csv(results, output_filename)

# ==============================================================================
# 5. DATA QUALITY AND SUMMARY ANALYSIS
# ==============================================================================

# Check for missing data
missing_data <- sum(is.na(results$temperature_C))
total_records <- nrow(results)
missing_percentage <- (missing_data / total_records) * 100

cat("Total records:", total_records, "\n")
cat("Missing temperature values:", missing_data, "\n")
cat("Missing data percentage:", round(missing_percentage, 2), "%\n")

# Display overall data summary
print(summary(results$temperature_C))

# Summary by site
temp_summary_site <- results |>
  group_by(site_code) |>
  summarise(
    mean_temp = round(mean(temperature_C, na.rm = TRUE), 2),
    min_temp = round(min(temperature_C, na.rm = TRUE), 2),
    max_temp = round(max(temperature_C, na.rm = TRUE), 2),
    n_records = n(),
    n_missing = sum(is.na(temperature_C)),
    years_covered = paste(range(year, na.rm = TRUE), collapse = "-")
  ) |>
  print()

# Summary by year
year_summary <- results |>
  group_by(year) |>
  summarise(
    mean_temp = round(mean(temperature_C, na.rm = TRUE), 2),
    n_records = n(),
    n_missing = sum(is.na(temperature_C)),
    n_sites = n_distinct(site_code),
    n_months = n_distinct(month)
  ) |>
  print()

# Monthly patterns across all years
monthly_summary <- results |>
  group_by(month) |>
  summarise(
    mean_temp = round(mean(temperature_C, na.rm = TRUE), 2),
    min_temp = round(min(temperature_C, na.rm = TRUE), 2),
    max_temp = round(max(temperature_C, na.rm = TRUE), 2),
    n_records = n()
  ) |>
  print()

# ==============================================================================
# 6. CREATE VISUALIZATIONS
# ==============================================================================

# Plot 1: Monthly temperature patterns by site
p1 <- ggplot(results, aes(x = factor(month), y = temperature_C, fill = site_code)) +
    geom_boxplot() +
    labs(title = "Monthly Temperature Patterns by Site (2000-2019)",
         x = "Month", y = "Temperature (°C)",
         fill = "Site code") +
    theme_minimal() +
    theme(axis.text.x = element_text(angle = 0))
p1

# Plot 2: Annual temperature trends
annual_data <- results |>
    group_by(year, site_code) |>
    summarise(annual_temp = mean(temperature_C, na.rm = TRUE), .groups = "drop")

p2 <- ggplot(annual_data, aes(x = year, y = annual_temp, color = site_code)) +
    geom_smooth(method = "lm", se = TRUE, alpha = 0.3) +
    # geom_line(linewidth = 1, linetype = 1) +
    geom_point(size = 2) +
    labs(title = "Annual Mean Temperature Trends (2000-2019)",
         x = "Year", y = "Annual Mean Temperature (°C)",
         color = "Site code") +
    theme_minimal() +
    scale_x_continuous(breaks = seq(2000, 2019, 2))
p2
