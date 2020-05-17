#!/bin/bash
cd layer
echo "creating layer.zip"
zip -r ../layer.zip ./*

cd ../function
echo "creating function.zip"
zip -r ../function.zip ./*
cd ..
