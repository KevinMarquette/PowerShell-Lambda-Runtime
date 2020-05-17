#!/bin/bash
cd layer
echo "creating layer.zip"
chmod 755 bootstrap
chmot 755 powershell/pwsh
zip -r ../layer.zip ./*

cd ../function
echo "creating function.zip"
zip -r ../function.zip ./*
cd ..
