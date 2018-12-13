# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

function Main {
    # Create test result
    $currentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true
        # role-0 vm is considered as the client-vm
        # role-1 vm is considered as the server-vm
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "role-0") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "role-1") {
                $noServer = $false
                $serverVMData = $vmData
            }
        }
        if ($noClient -or $noServer) {
            Throw "Client or Server VM not defined. Be sure that the SetupType has 2 VMs defined"
        }

        #region CONFIGURE VM FOR TERASORT TEST
        Write-LogInfo "CLIENT VM details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
        Write-LogInfo "SERVER VM details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by LISAv2 Automation" -Path $constantsFile
        Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            if ($param -imatch "pingIteration") {
                $pingIteration=$param.Trim().Replace("pingIteration=","")
            }
            Add-Content -Value "$param" -Path $constantsFile
        }
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        #endregion

        #region EXECUTE TEST
        $myString = @"
cd /root/
./perf_lagscope.sh &> lagscopeConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartLagscopeTest.sh" $myString
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\StartLagscopeTest.sh" -username "root" -password $password -upload
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

        $null = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
        $testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartLagscopeTest.sh" -RunInBackground
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 lagscopeConsoleLogs.txt"
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }
        $finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "lagscope-n$pingIteration-output.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

        $testSummary = $null
        $lagscopeReportLog = Get-Content -Path "$LogDir\lagscope-n$pingIteration-output.txt"
        Write-LogInfo $lagscopeReportLog
        #endregion

        try {
            $matchLine= (Select-String -Path "$LogDir\lagscope-n$pingIteration-output.txt" -Pattern "Average").Line
            $minimumLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[1]
            $maximumLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[3]
            $averageLat = $matchLine.Split(",").Split("=").Trim().Replace("us","")[5]

            $currentTestResult.TestSummary += New-ResultSummary -testResult $minimumLat -metaData "Minimum Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            $currentTestResult.TestSummary += New-ResultSummary -testResult $maximumLat -metaData "Maximum Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            $currentTestResult.TestSummary += New-ResultSummary -testResult $averageLat -metaData "Average Latency" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        } catch {
            $currentTestResult.TestSummary += New-ResultSummary -testResult "Error in parsing logs." -metaData "LAGSCOPE" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }

        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        }
        elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell background job is completed but VM is reporting that test is still running. Please check $LogDir\ConsoleLogs.txt"
            Write-LogInfo "Contents of summary.log : $testSummary"
            $testResult = "PASS"
        }
        Write-LogInfo "Test result : $testResult"
        Write-LogInfo "Test Completed"

        Write-LogInfo "Uploading the test results.."
        $dataSource = $xmlConfig.config.$TestPlatform.database.server
        $user = $xmlConfig.config.$TestPlatform.database.user
        $password = $xmlConfig.config.$TestPlatform.database.password
        $database = $xmlConfig.config.$TestPlatform.database.dbname
        $dataTableName = $xmlConfig.config.$TestPlatform.database.dbtable
        $TestCaseName = $xmlConfig.config.$TestPlatform.database.testTag
        if ($dataSource -And $user -And $password -And $database -And $dataTableName)  {
            $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| ForEach-Object {$_ -replace ",OS type,",""}
            $HostOS = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
            $GuestOSType = "Linux"
            $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
            $GuestSize = $clientVMData.InstanceSize
            $KernelVersion = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
            $IPVersion = "IPv4"
            $ProtocolType = "TCP"
            if($EnableAcceleratedNetworking -or ($currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV")) {
                $DataPath = "SRIOV"
            } else {
                $DataPath = "Synthetic"
            }
            $SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,IPVersion,ProtocolType,DataPath,MaxLatency_us,AverageLatency_us,MinLatency_us,Latency95Percentile_us,Latency99Percentile_us) VALUES "

            #Percentile Values are not calculated yet. will be added in future.
            $Latency95Percentile_us = 0
            $Latency99Percentile_us = 0

            $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$TestPlatform','$TestLocation','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$IPVersion','$ProtocolType','$DataPath','$maximumLat','$averageLat','$minimumLat','$Latency95Percentile_us','$Latency99Percentile_us'),"

            $SQLQuery = $SQLQuery.TrimEnd(',')
            Upload-TestResultToDatabase $SQLQuery
        }
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }

    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}

Main
