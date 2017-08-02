
-   [RSPrePro: Download and preprocess Remote Sensing images (Sentinal-2 and Landsat)](#rsprepro-download-and-preprocess-remote-sensing-images-sentinal-2-and-landsat)
    -   [Warning](#warning)
    -   [Installation](#installation)

<!-- README.md is generated from README.Rmd. Please edit that file -->
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](http://www.gnu.org/licenses/gpl-3.0)

RSPrePro: Download and preprocess Remote Sensing images (Sentinal-2 and Landsat)
================================================================================

Warning
-------

This package is under construction: for now only the functions documented in the [function references](http://ggranga.github.io/RSPrePro/reference) are working. Moreover, the download and atmospheric correction on Sentinel-2 data [s2tsp](http://github.com/ggranga/s2tsp) was not yet implemented in this R interface, so it must be runned using [python scripts](http://github.com/ggranga/s2tsp).

Installation
------------

You can install RSPrePro from github with:

``` r
# install.packages("devtools")
devtools::install_github("ggranga/RSPrePro")
```
