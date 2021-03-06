#' @title Correct L1C products using sen2cor
#' @description The function uses sen2cor to manually correct L1C products.
#'  Standalone version of 
#'  [sen2cor 2.5.5](http://step.esa.int/main/third-party-plugins-2/sen2cor)
#'  is used.
#' @param l1c_prodlist List of L1C product names to be corrected. They can be both
#'  product names with full/relative path or only names of SAFE products (in this case, also
#'  l1c_dir argument must be provided). SAFE products must be unzipped.
#'  Note that, at this stage, all products must be in the same directory (this will be fixed).
#' @param l1c_dir Full or relative path of input L1C products.
#'  If NULL (default), `l1c_prodlist` must already be a vector of full paths.
#' @param outdir Directory where output L2A products will be placed.
#'  If NULL (default), each product is left in the parent directory of `l1c_prodlist`.
#' @param proc_dir (optional) Directory where processing is applied.
#'  If NA (default), processing is done in `l1c_dir` and output L2A product is 
#'  then moved to `outdir`, unless `l1c_dir` is a subdirectory of a SAMBA mountpoint under Linux:
#'  in this case, L1C input products are copied in a temporary directory
#'  (specified with argument `tmpdir`), 
#'  processing is done there and then L2A is moved to `outdir`. 
#'  This is required under Linux systems when `l1c_dir` is a subdirectory of
#'  a unit mounted with SAMBA, otherwise sen2cor would produce empty L2A products.
#' @param tmpdir (optional) Path where processing is performed if a temporary
#'  working directory is required (see argument `proc_dir`). Be sure `tmpdir`
#'  not to be a SAMBA mountpoint under Linux.
#'  Default is a temporary directory.
#' @param rmtmp (optional) Logical: should temporary files be removed?
#'  (Default: TRUE)
#' @param tiles Vector of Sentinel-2 Tile strings (5-length character) to be 
#'  processed (default: process all the tiles found in the input L1C products).
#' @param parallel (optional) Logical: if TRUE, sen2cor instances are launched 
#'  in parallel using multiple cores; if FALSE (default), they are launched in 
#'  series on a single core. 
#'  The number of cores is automatically determined; specifying it is also 
#'  possible (e.g. `parallel = 4`).
#' @param overwrite Logical value: should existing output L2A products be overwritten?
#'  (default: FALSE)
#' @param .log_message (optional) Internal parameter
#'  (it is used when the function is called by `sen2r()`).
#' @param .log_output (optional) Internal parameter
#'  (it is used when the function is called by `sen2r()`).
#' @return Vector character with the list ot the output products (being corrected or already
#'  existing)
#'
#' @author Luigi Ranghetti, phD (2017) \email{ranghetti.l@@irea.cnr.it}
#' @note License: GPL 3.0
#' @importFrom jsonlite fromJSON
#' @importFrom doParallel registerDoParallel
#' @importFrom foreach foreach "%do%" "%dopar%"
#' @importFrom parallel detectCores makeCluster stopCluster
#' @export
#'
#' @examples \dontrun{
#' pos <- st_sfc(st_point(c(12.0, 44.8)), crs=st_crs(4326))
#' time_window <- as.Date(c("2017-05-01","2017-07-30"))
#' example_s2_list <- s2_list(spatial_extent=pos, tile="32TQQ", time_interval=time_window)
#' s2_download(example_s2_list, outdir=tempdir())
#' sen2cor(names(example_s2_list)[1], l1c_dir=tempdir(), outdir=tempdir())
#' }

sen2cor <- function(l1c_prodlist=NULL, l1c_dir=NULL, outdir=NULL, proc_dir=NA, 
                    tmpdir = NA, rmtmp = TRUE,
                    tiles=NULL, parallel=FALSE, overwrite=FALSE,
                    .log_message=NA, .log_output=NA) {
  
  # load sen2cor executable path
  binpaths <- load_binpaths("sen2cor")
  
  # tiles NA -> NULL
  if (!is.null(tiles)) {
    if (all(is.na(tiles))) {tiles <- character(0)}
  }
  
  # if l1c_dir is defined, append to product names
  if (!is.null(l1c_dir)) {
    l1c_prodlist <- file.path(l1c_dir,l1c_prodlist)
  }
  
  # # check that all products are in the same directory (FIXME allow differents <- need to change call_sen2cor)
  # if (length(unique(dirname(l1c_prodlist)))>1) {
  #   print_message(
  #     type="error",
  #     "All input products must be in the same folder (this will be fixed to allow different ones).")
  # }
  
  # check that proc_dir is not on a mountpoint
  if (!is.na(proc_dir) & Sys.info()["sysname"] != "Windows") {
    if (any(attr(mountpoint(proc_dir), "protocol") %in% c("cifs", "nsfs"))) {
      print_message(
        type = "warning",
        proc_dir, "is on a SAMBA mounted unit, so it will not be used."
      )
      proc_dir <- NA
    }
  }
  
  # accept only input names which are L1C
  l1c_prodlist_level <- sapply(l1c_prodlist, function(x) {
    tryCatch(
      safe_getMetadata(x, info = "level"),
      error = function(y){"wrong"}
    )
  })
  l1c_prodlist <- l1c_prodlist[l1c_prodlist_level=="1C"]
  
  # if no products were found, exit
  if (length(l1c_prodlist) == 0) {
    print_message(
      type = "warning",
      "No valid L1C products were found,"
    )
    return(invisible(NULL))
  }
  
  ## Cycle on each file
  # if parallel==TRUE, use doParallel
  n_cores <- if (is.numeric(parallel)) {
    as.integer(parallel)
  } else if (parallel==FALSE) {
    1
  } else {
    min(parallel::detectCores()-1, length(l1c_prodlist), 8) # use at most 8 cores
  }
  # if (parallel==FALSE | Sys.info()["sysname"] == "Windows" | n_cores<=1) {
  if (parallel==FALSE | n_cores<=1) {
    `%DO%` <- `%do%`
    parallel <- FALSE
    n_cores <- 1
  } else {
    `%DO%` <- `%dopar%`
    cl <- makeCluster(n_cores)
    registerDoParallel(cl)
  }
  
  # cycle on eacjh product
  l2a_prodlist <- foreach(
    i=seq_along(l1c_prodlist), 
    .combine=c,
    .export = "mountpoint",
    .packages='sen2r'
  ) %DO% {
    
    # redirect to log files
    if (n_cores > 1) {
      if (!is.na(.log_output)) {
        sink(.log_output, split = TRUE, type = "output", append = TRUE)
      }
      if (!is.na(.log_message)) {
        logfile_message = file(.log_message, open = "a")
        sink(logfile_message, type="message")
      }
    }
    
    # set paths
    sel_l1c <- l1c_prodlist[i]
    sel_l2a <- file.path(
      if (is.null(outdir)) {dirname(sel_l1c)} else {outdir},
      gsub(
        "_MSIL1C\\_", "_MSIL2A_",
        gsub("_OPER_", "_USER_", basename(sel_l1c))
      )
    ) # path of the L2A product where it should be placed definitively
    
    ## Set the tiles vectors (existing, required, ...)
    # existing L1C tiles within input product
    sel_l1c_tiles_existing <- sapply(
      list.files(file.path(sel_l1c,"GRANULE")), 
      function(x){safe_getMetadata(x,"nameinfo")$id_tile}
    )
    # L2A tiles already existing
    sel_l2a_tiles_existing <- if (file.exists(sel_l2a)) {
      sapply(
        list.files(file.path(sel_l2a,"GRANULE")), 
        function(x){safe_getMetadata(x,"nameinfo")$id_tile}
      )
    } else {
      character(0)
    }
    # L2A tiles required as output (already existing or not)
    sel_l2a_tiles_required <- if (length(tiles)==0) {
      sel_l1c_tiles_existing
    } else {
      sel_l1c_tiles_existing[sel_l1c_tiles_existing %in% tiles]
    }
    # L2A tiles to be corrected (= required and not yet existing)
    sel_l2a_tiles_tocorrect <- sel_l2a_tiles_required[
      !sel_l2a_tiles_required %in% sel_l2a_tiles_existing
      ]
    # L1C tiles not required to be corrected
    sel_l1c_tiles_unnecessary <- sel_l1c_tiles_existing[
      !sel_l1c_tiles_existing %in% sel_l2a_tiles_tocorrect
      ]
    # L1C tiles to be manually excluded before applying sen2cor in order
    # not to process them (= tiles present within input L1C product
    # and not already esisting as L2A, because in this case sen2cor would
    # automatically skip them)
    sel_l1c_tiles_toavoid <- sel_l1c_tiles_unnecessary[
      !sel_l1c_tiles_unnecessary %in% sel_l2a_tiles_existing
      ]
    
    ## Continue only if not all the existing tiles have already been corrected
    ## (or if the user chosed to overwrite)
    if (overwrite==TRUE | length(sel_l2a_tiles_tocorrect)>0) {
      
      # if output exists (and overwrite==TRUE), delete it
      if (overwrite==TRUE) {unlink(sel_l2a)}
      
      # set a temporary proc_dir in the following three cases:
      # 1) if some L1C tiles need to be manually excluded;
      # 2) if dirname(sel_l1c)!=dirname(sel_l2a) & input L1C was already partially corrected
      #    (to avoid the risk to process more tiles than required);
      # 3) if sel_l1c is on a SAMBA mountpoint (because sen2cor does not process
      #    correctly in this case)
      sel_proc_dir <- proc_dir
      if (is.na(proc_dir)) {
        if (
          length(sel_l1c_tiles_toavoid)>0 | # 1
          dirname(sel_l1c)!=dirname(sel_l2a) & length(sel_l2a_tiles_existing)>0 | # 2
          Sys.info()["sysname"] != "Windows" & any(attr(suppressWarnings(mountpoint(sel_l1c)), "protocol") %in% c("cifs", "nsfs")) # 3
        ) {
          if (is.na(tmpdir)) {
            tmpdir <- tempfile(pattern="sen2cor_")
          }
          dir.create(tmpdir, recursive=FALSE, showWarnings=FALSE)
          # check that tmpdir is not on a mountpoint
          if (Sys.info()["sysname"] != "Windows") {
            if (any(attr(mountpoint(tmpdir), "protocol") %in% c("cifs", "nsfs"))) {
              print_message(
                type = "error",
                tmpdir, "is on a SAMBA mounted unit, so it can not be used."
              )
            }
          }
          sel_proc_dir <- tmpdir
        }
      }
      
      # if proc_dir is [manually or automatically] set, copy sel_l1c
      if (!is.na(sel_proc_dir)) {
        use_tmpdir <- TRUE
        dir.create(sel_proc_dir, recursive=FALSE, showWarnings=FALSE)
        if (length(sel_l1c_tiles_unnecessary)>0) {
          # if some tiles is unnecessary, copy only necessary files
          dir.create(file.path(sel_proc_dir,basename(sel_l1c)))
          sel_l1c_files <- list.files(sel_l1c, recursive=FALSE, full.names=FALSE)
          file.copy(
            file.path(sel_l1c,sel_l1c_files[!grepl("^GRANULE$",sel_l1c_files)]),
            file.path(sel_proc_dir,basename(sel_l1c)),
            recursive = TRUE
          )
          dir.create(file.path(sel_proc_dir,basename(sel_l1c),"GRANULE"))
          file.copy(
            file.path(sel_l1c,"GRANULE",names(sel_l2a_tiles_tocorrect)),
            file.path(sel_proc_dir,basename(sel_l1c),"GRANULE"),
            recursive = TRUE
          )
        } else {
          # else, copy the whole product
          file.copy(sel_l1c, sel_proc_dir, recursive=TRUE)
        }
        sel_l1c <- file.path(sel_proc_dir, basename(sel_l1c))
      } else {
        use_tmpdir <- FALSE
      }
      
      # path of the L2A product where it is placed by sen2cor
      sen2cor_out_l2a <- file.path(
        dirname(sel_l1c),
        gsub(
          "_MSIL1C\\_", "_MSIL2A_",
          gsub("_OPER_", "_USER_", basename(sel_l1c))
        )
      )
      
      # apply sen2cor
      trace_paths <- if (use_tmpdir) {
        c(sel_l1c, sen2cor_out_l2a)
      } else if (overwrite==TRUE | !file.exists(sen2cor_out_l2a)) {
        sen2cor_out_l2a
      } else {
        file.path(sen2cor_out_l2a,"GRANULE",names(sel_l2a_tiles_tocorrect))
      }
      sel_trace <- start_trace(trace_paths, "sen2cor")
      system(
        paste(binpaths$sen2cor, "--refresh", sel_l1c),
        intern = Sys.info()["sysname"] == "Windows"
      )
      if (TRUE) { # TODO define a way to check if sen2cor ran correctly
        end_trace(sel_trace)
      } else {
        clean_trace(sel_trace)
      }
      
      # move output to the required output directory
      if (use_tmpdir | dirname(sen2cor_out_l2a)!=dirname(sel_l2a)) {
        file.copy(sen2cor_out_l2a, dirname(sel_l2a), recursive=TRUE, overwrite=TRUE)
        if (rmtmp == TRUE) {
          unlink(sen2cor_out_l2a, recursive=TRUE)
        }
      } 
      if (use_tmpdir & rmtmp == TRUE) {
        unlink(sel_l1c, recursive=TRUE)
      }
      
    } # end IF cycle on overwrite
    
    # stop sinking
    if (n_cores > 1) {
      if (!is.na(.log_output)) {
        sink(type = "output")
      }
      if (!is.na(.log_message)) {
        sink(type = "message"); close(logfile_message)
      }
    }
    
    sel_l2a
    
  } # end FOREACH cycle on each product
  if (n_cores > 1) {
    stopCluster(cl)
  }
  
  # Remove temporary directory
  if (rmtmp == TRUE & !is.na(tmpdir)) {
    unlink(tmpdir, recursive=TRUE)
  }
  
  return(l2a_prodlist)
  
}
