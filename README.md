# Custom PowerShell 7 Lambda Runtime
This is a custom PowerShell runtime that takes a different approach than the PowerShell runtime provided by AWS Lambda. It was built as a proof of concept that captures the spirit of PowerShell. Feel free to experiment with it but it should not be used for production workloads.

# Creating a PowerShell Lambda
Start by creating a PowerShell module in your project folder. Then add a function to that module that takes at least 2 positional parameters. It should look something like this:

``` powershell
function Test-MyLambda
{
    [CmdletBinding()]
    param(
        [parameter()]
        $InputObject,

        [parameter()]
        $Context
    )
    "Standard Pipeline is returned"
    "Like you would expect from a PowerShell function"
}
```

You can name the function or parameters anything you want. The first parameter is the event data passed into the lambda. The second is a context hashtable that contains other metadata from the header that came with the event data.

If the input has a content type of `application/json` then the input is converted into a hashtable before passed to the function.

Everything placed on the pipeline is returned from the lambda as output. Unhandled exceptions are caught by the runtime, then they are logged to the log stream and a error result is returned to the caller. All your `Write-Host`,`Write-Verbose`, and `Write-Warning` output is added to your lambda's log stream.

When you publish the lambda, you specify the handler as `MyModule.MyFunction`. The example project uses `example.Test-MyLambda` as the handler. I'll go into more detail on this in a later section.

## Required Modules
I don't have any fancy module packaging logic built yet. If you require a module, create a `./modules` folder and place it in there. That folder gets added to the `$env:PSModulePath` so normal `Import-Module` rules apply.

If you don't want to check your modules into your project, consider adding a build script that uses `Save-Module` to save them into the `./modules` folder before publishing.

## PowerShell Scripts
I think using a module is the best approach, but I did add support for executing PowerShell scripts. All the same rules that apply to to using a function also apply to using a script.

``` powershell
[cmdletbinding()]
param(
    [parameter()]
    $InputObject,

    [parameter()]
    $Context
)
"Standard Pipeline is returned"
"Like you would expect from a PowerShell script"
```

The handler for a script is just the path to the script. So it would be something like `./MyScript.ps1`.

## Lambda handler details
The handler uses a `MyModule.MyFunction` format. You can specify the module part in two different ways.

`MyModule` can be just the name of the module if you place it at the root of the project. So `MyModule.MyFunction` will find a module at `./MyModule.psd1`. It will also find your module if it is placed in a folder same name at the root of the project (`./MyModule/MyModule.psd1`) or in a `./modules` folder (`./modules/MyModule/MyModule.psd1`). Those last two patterns works because the working folder and the `./modules` folder are added to the `$env:PSModulePath` so normal module discovery rule apply there.

`MyModule` can also be the relative path to the `pds1` or `psm1` file. If you place it in the root of your project, you can use `./MyModule.psd1.MyFunction`. If you place it in a sub folder, specify that folder `./src/MyModule.psd1.MyFunction`. Remember to use the forward slash because the lambda runs on Linux.

The handler also supports providing the path to a script if you decide to use a script instead of a module. You would then specify the handler as `./MyScript.ps1` to execute a script in the root of the project. No modules required.

# Publishing with the Runtime

## Downloading PowerShell
Download PowerShell from `https://github.com/PowerShell/PowerShell/releases` and extract content to `./layer/powershell`. You should have `pwsh` located at `./layer/powershell/pwsh` when you unzip it. Make sure you get a `linux-x64.tar.gz` package because it needs to execute in the lambda.

I didn't include them in the repository because the version changes quite often and I didn't really want to check in all those binaries. So make sure you add PowerShell to the project before you publish it.

I used [powershell-7.0.1-linux-x64.tar.gz](https://github.com/PowerShell/PowerShell/releases/download/v7.0.1/powershell-7.0.1-linux-x64.tar.gz) while developing this custom runtime.

## Publish runtime as a Lambda Layer
To use this runtime, we need to publish it as a layer. You only have to do this one and use this layer for multiple lambdas. You can even share your layer with other accounts.

zip the contents of the layer folder:

``` bash
#!/bin/bash
cd layer
zip -r ../layer.zip ./*
```

Upload it to S3 and publish it as a lambda layer. Save the `LayerVersionArn` for later.

``` PowerShell
Write-S3Object -BucketName $S3Bucket -File .\layer.zip

$LMLayerVersion = @{
    CompatibleRuntime = 'dotnetcore3.1'
    Description = 'Custom pwsh runtime'
    LayerName = 'pwsh-runtime'
    LicenseInfo = 'mit'
    Content_S3Bucket = $S3Bucket
    Content_S3Key = 'layer.zip'
}
$layer = Publish-LMLayerVersion @LMLayerVersion
$layer.LayerVersionArn
```

We have to upload to S3 first because the size of the package is too large to upload it directly to the lambda.

## Publish your PowerShell lambda

Now we need tp publish our PowerShell project as a lambda that uses the runtime layer we just created.

zip up your lambda:

``` bash
#!/bin/bash
cd function
zip -r ../function.zip ./*
```

Then upload it to S3 and publish it using our runtime as a layer.

``` powershell
Write-S3Object -BucketName $S3Bucket -File .\function.zip

$LMFunction = @{
    TimeOut = 7
    Code_S3Bucket = $S3Bucket
    Code_S3Key = 'function.zip'
    FunctionName = 'pwsh-runtime'
    handler = 'example.Test-Lambda'
    layer = $layer.LayerVersionArn
    Role = $LambdaRoleArn
    Runtime = 'provided'
}
Publish-LMFunction @LMFunction
```
You can optionally specify the zip with `Publish-LMfunction` instead of uploading to S3 first.

One important detail to call out is that we have to specify a `TimeOut`.

## Executing the lambda

Placing this here for easy copy and paste execution.

``` PowerShell
$Result = Invoke-LMFunction -FunctionName pwsh-runtime -Payload '{"hello":"World"}'
[System.IO.StreamReader]::new($Result.Payload).ReadToEnd()
```
## CDK
I was using the bash zip command to create the package before uploading it. The CDK should be able to deploy the lambda folder as an asset for you. I will explore using the CDK for the deployment later. I was already using the PowerShell commands and it was easier to just capture them here.

# Edit in the AWS Console

One of the other benefits of placing the custom runtime in its own layer and only having your powershell project deployed as the lambda is that you can view and edit the lambda from the AWS Lambda Console. How cool is that.

# Important Call Outs and Known Issues

## AWS.Tools
The AWS.Tools PowerShell module is not included. You will have to add the modules that you need into your `./modules` folder.

## Errors

Unhandled errors and exceptions are caught by the runtime and will produce an error like this.

``` json
{
  "errorType": "RuntimeException",
  "errorMessage": "No Execution for you",
  "context": {
    "AWS_LAMBDA_LOG_GROUP_NAME": "/aws/lambda/pwsh-runtime",
    "AWS_LAMBDA_LOG_STREAM_NAME": "2020/05/17/[$LATEST]90b8dab6af2143d0b1c98e8781c6e7b7",
    "Lambda-Runtime-Aws-Request-Id": "39e701b4-20cc-4657-a40f-4e516dd8370e",
    "Debug": "false",
    "Debug_Message": "Set Debug="true" as an environment variable for all environment variables, headers, and ErrorRecord details."
  }
}
```

If you want your lambda to show that it failed, then throw an exception or create an error that you don't catch in your code. If you do implement your own error handling, you can rethrow the exception to show failure.

``` powershell
catch
{
    Send-MyCustomLog -Message $PSItem
    throw
}
```

Use of `ThrowTerminatingError` will also work correctly with this runtime.

``` powershell
catch
{
    $PSCmdlet.ThrowTerminatingError( $PSItem )
}
```

### CloudWatch logs
I added `AWS_LAMBDA_LOG_GROUP_NAME` and `AWS_LAMBDA_LOG_STREAM_NAME` to the error so you can pull the CloudWatch logs directly.

``` powershell
$logGroup = $result.context.AWS_LAMBDA_LOG_GROUP_NAME
$logStream = $result.context.AWS_LAMBDA_LOG_STREAM_NAME
Get-CWLLogEvent -LogGroupName $logGroup -LogStreamName $logStream |
    Select-Object -ExpandProperty events
```

You may need to run `ConvertFrom-Json` on your `$result` first.

### Debug Mode
If you set `Debug` mode to `true` in the environment for your lambda, then the returned error object will have additional information. You get a response that looks like this:

``` json
{
  "errorType": "RuntimeException",
  "errorMessage": "No Execution for you",
  "errorRecord": {
    "stackTrace": null,
    "targetObject": "No Execution for you",
    "errorDetails": null,
    "source": null,
    "targetSite": "",
    "scriptStackTrace": [
      "at Test-Lambda, /var/task/modules/example/example.psm1: line 15",
      "at <ScriptBlock>, /opt/runtime.ps1: line 42"
    ],
    "fullyQualifiedErrorId": "No Execution for you"
  },
  "context": {
    "AWS_SECRET_ACCESS_KEY": "XXXXXXXXXXXXXXX",
    "AWS_XRAY_CONTEXT_MISSING": "LOG_ERROR",
    "TZ": ":UTC",
    "AWS_LAMBDA_RUNTIME_API": "127.0.0.1:9001",
    "AWS_ACCESS_KEY_ID": "XXXXXXXXXX",
    "PSModulePath": "/var/task:/var/task/modules:/opt/modules:/opt/powershell/modules",
    "AWS_REGION": "us-west-2",
    "PWD": "/opt",
    "LAMBDA_RUNTIME_DIR": "/var/runtime",
    "_X_AMZN_TRACE_ID": "Root=1-5ec0b34e-692317274b665c2967938f32;Parent=42df998801542f26;Sampled=0",
    "AWS_LAMBDA_FUNCTION_NAME": "pwsh-runtime",
    "LANG": "en_US.UTF-8",
    "LD_LIBRARY_PATH": "/lib64:/usr/lib64:/var/runtime:/var/runtime/lib:/var/task:/var/task/lib:/opt/lib",
    "_HANDLER": "example.Test-Lambda",
    "AWS_LAMBDA_FUNCTION_VERSION": "$LATEST",
    "AWS_XRAY_DAEMON_ADDRESS": "169.0.0.0:2000",
    "OLDPWD": "/var/task",
    "LAMBDA_TASK_ROOT": "/var/task",
    "AWS_SESSION_TOKEN": "XXXXXXXXXXXXXXXXXXXXXX",
    "SHLVL": "1",
    "AWS_LAMBDA_LOG_GROUP_NAME": "/aws/lambda/pwsh-runtime",
    "_": "./powershell/pwsh",
    "AWS_LAMBDA_LOG_STREAM_NAME": "2020/05/17/[$LATEST]90b8dab6af2143d0b1c98e8781c6e7b7",
    "_AWS_XRAY_DAEMON_PORT": "2000",
    "_AWS_XRAY_DAEMON_ADDRESS": "169.0.0.0",
    "AWS_DEFAULT_REGION": "us-west-2",
    "AWS_LAMBDA_FUNCTION_MEMORY_SIZE": "128",
    "PATH": "/opt/powershell:/usr/local/bin:/usr/bin/:/bin:/opt/bin",
    "Debug": "true"
  }
}
```

This can be added with `Update-LMFunctionConfiguration`.

``` PowerShell
Update-LMFunctionConfiguration -FunctionName pwsh-runtime -Environment_Variables @{
    Debug = 'true'
}
```
### ErrorActionPreference
The runtime sets `$ErrorActionPreference = "Stop"` before executing your code. This is done to ensure that errors are handled by the exception handler and report correctly.

If this is causing your scripts to fail in unexpected places, then review how you are doing error handling.

### Errors and the Pipeline
If your function or script throws an unhandled exception, then the only output that will be returned from the lambda are details about the error. Any data that you would have placed on the pipeline is discarded. This is both a side effect of PowerShell and a limitation of the runtime interface.

When I execute your code, I capture the results into a variable. When an unhandled exception happens, that variable never gets assigned any output because execution jumps to the next `catch` block.

Even if I could capture your output, the runtime interface gives me one endpoint for success that returns the provided output, and a different one for errors that only provides the error details.

## Cold Boot

The default `TimeOut` of 3 sec is too short and your lambda will not initialize in time if it is not increased. That is the largest issue with this runtime. The primary contributor to this delay comes from copying the 60M of files that is PowerShell 7. This only applies to cold starts.

I ran 6 batches of 5 executions with various delays between them. I captured 2 cold starts. Here are the times are in total seconds.

``` powershell
# first run
#2020-05-16 23:11:18
5.1647055 # cold start
0.4388794
1.1788271
1.3395028
0.3654994

#2020-05-16 23:12:23
0.9531519
0.6993305
0.7193744
0.6000545
0.9606102

#2020-05-16 23:12:39
1.1019578
1.4182378
1.1805631
1.2603942
0.7393591

#2020-05-16 23:13:46
0.6919624
0.9364316
0.8200026
1.1798993
0.280223

#2020-05-16 23:15:39
0.36394
0.2798568
0.9593924
0.2599845
0.8799651

# long delay
# 2020-05-16 23:33:35
4.8217827 # Cold start
0.7979347
0.7824545
1.2772624
0.5396393
```

### Task timed out after 3.01 seconds

If you get an error like this:

```
{"errorMessage":"2020-05-17T03:52:20.759Z 23f3e487-7359-4384-8362-7cd158e34be6 Task timed out after 3.01 seconds"}
```
Then you need to increase the `TimeOut` value on the lambda.

``` PowerShell
 Update-LMFunctionConfiguration -FunctionName pwsh-runtime -Timeout 7
```

### Task timed out after 7.01 seconds

If you get an error like this:

```
{"errorMessage":"2020-05-17T03:52:20.759Z 9d73e487-7359-4384-8362-7cd158e34af9 Task timed out after 7.01 seconds"}
```
Then check the cloud watch logs for issues. This can happen if there are issues in the custom runtime error handling and it is not able to post error details correctly. Or if there are errors with the environment that

## Context
The `Context` object that is passed as the second parameter is not the same context object that Lambda passes to other handlers. I just tossed several things in there for now. I need to go back to the specification and refactor it to better match the documentation. It's not critical at this point, but the more I can align with the specification the more intuitive it will be for users moving from one runtime to another.

### ClientContext/MobileContext
`ClientContext` and `MobileContext` are not implemented. I saw some details related to them but was able to get the project working by ignoring them. This may be left up to whoever needs it to add it. I think its just pulling more details from the environment or request header and adding it to the `Context` object.

## Shared Execution Environment

Multiple executions can execute in the same PowerShell session as previous executions. Each execution is in its own scope so any locally scoped variables will be cleared out between execution. Globally scoped and environment variables can persist across lambda calls. Some modules will also internally maintain state that may persist.

## Amazon X-Ray
I am not sure if Amazon X-Ray is implemented correctly. What I have is untested and feels like it should not be enough.

## Positional Parameters

You may notice I called out that two positional parameters are required but I did not specify a position in the examples. This is because PowerShell will automatically assign them positions in order they are listed unless you override it by specifying a position. If you change the order or place other parameters in front of these two required ones, go a head and specify a position.

The reason why I am using positional parameters is because I am executing your function or script like this:

``` PowerShell
$body = & $function $eventData $context -Verbose | Out-String
```

By providing the values positionally, I don't have to force you to use specific names for the parameters.

### Don't name it $Input

And Whatever you do, do not name your parameter `$Input`. Thats a magic variable in a function that is overwritten with data from the pipeline. You could easily spend hours trying to figure out why your not getting the data you expect. I know I did.

## Marking binaries as executable
Something I did early on while trying to figure out how to get my runtime to run is mark two files as executable. I don't know if its really needed but calling it out just in case.

``` bash
chmod 755 ./layer/bootstrap
chmod 755 ./layer/powershell/pwsh
```
## PowerShell Preview
If you want to use a preview or release candidate of PowerShell, you will need to edit the `./layer/bootstrap` file to specify `pwsh-preview` instead of `pwsh`. This is the only file that directly references the `pwsh` executable.

``` powershell
#!/usr/bin/env /opt/powershell/pwsh-preview
```

Download your desired release version and add it to the `./layer/powershell` folder just like you would for regular PowerShell.

## Additional Documentation

Everything I needed to create this runtime was found in the AWS Lambda documentation. If you would like more information on what it takes to build your own runtime or just understand this project better, take a look at these links.

* [Custom AWS Lambda runtimes](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html)
* [AWS Lambda runtime interface](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html)
* [Tutorial – Publishing a custom runtime](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-walkthrough.html)