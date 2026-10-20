$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
kind delete cluster --name restaurant-api
