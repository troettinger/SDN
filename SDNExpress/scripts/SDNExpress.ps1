﻿# --------------------------------------------------------------
#  Copyright © Microsoft Corporation.  All Rights Reserved.
#  Microsoft Corporation (or based on where you live, one of its affiliates) licenses this sample code for your internal testing purposes only.
#  Microsoft provides the following sample code AS IS without warranty of any kind. The sample code arenot supported under any Microsoft standard support program or services.
#  Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose.
#  The entire risk arising out of the use or performance of the sample code remains with you.
#  In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the code be liable for any damages whatsoever
#  (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss)
#  arising out of the use of or inability to use the sample code, even if Microsoft has been advised of the possibility of such damages.
# ---------------------------------------------------------------
<#
.SYNOPSIS 
    Deploys and configures the Microsoft SDN infrastructure, 
    including creation of the network controller, Software Load Balancer MUX 
    and gateway VMs.  Then the VMs and Hyper-V hosts are configured to be 
    used by the Network Controller.  When this script completes the SDN 
    infrastructure is ready to be fully used for workload deployments.
.EXAMPLE
    .\SDNExpress -ConfigurationDataFile .\MyConfig.psd1
    Reads in the configuration from a PSD1 file that contains a hash table 
    of settings data.
.EXAMPLE
    .\SDNExpress -ConfigurationData $MyConfigurationData
    Uses the hash table that is passed in as the configuration data.  This 
    parameter set is useful when programatically generating the 
    configuration data.
.NOTES
    Prerequisites:
    * All Hyper-V hosts must have Hyper-V enabled and the Virtual Switch 
    already created.
    * All Hyper-V hosts must be joined to Active Directory.
    * The physical network must be preconfigured for the necessary subnets and 
    VLANs as defined in the configuration data.
    * The deployment computer must have the deployment directory shared with 
    Read/Write permissions for Everyone.
#>

[CmdletBinding(DefaultParameterSetName="NoParameters")]
param(
    [Parameter(Mandatory=$true,ParameterSetName="ConfigurationFile")]
    [String] $ConfigurationDataFile=$null,
    [Parameter(Mandatory=$true,ParameterSetName="ConfigurationData")]
    [object] $ConfigurationData=$null
)    



Configuration SetHyperVWinRMEnvelope
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node $AllNodes.Where{$_.Role -eq "HyperVHost"}.NodeName
    {
        Script SetWinRmEnvelope
        {                                      
            SetScript = {
                write-verbose "Settign WinRM Envelope size."
                Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 5000
            }
            TestScript = {
                return ((Get-Item WSMan:\localhost\MaxEnvelopeSizekb).Value -ge 5000)
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Configuration DeployVMs
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node $AllNodes.Where{$_.Role -eq "HyperVHost"}.NodeName
    {
        foreach ($VMInfo in $node.VMs) {
            File "CreateVMDirectory_$($VMInfo.VMName)"
            {
                Type = "Directory"
                Ensure = "Present"
                Force = $True
                DestinationPath = $node.VMLocation+"\"+$($VMInfo.VMName)                    
            }

            File "CopyOSVHD_$($VMInfo.VMName)"
            {
                Type = "File"
                Ensure = "Present"
                Force = $True
                SourcePath = $node.installSrcDir+"\"+$node.VHDSrcLocation+"\"+$node.VHDName
                DestinationPath = $node.VMLocation+"\"+$($VMInfo.VMName)+"\"+$node.VHDName
            }

            File "CheckTempDirectory_$($VMInfo.VMName)"
            {
                Type = "Directory"
                Ensure = "Present"
                Force = $True
                DestinationPath = ($node.MountDir+$($VMInfo.VMName))
            }

            Script "MountImage_$($VMInfo.VMName)"
            {                                      
                SetScript = {
                    $imagepath = $using:node.VMLocation+"\"+$using:vminfo.VMName+"\"+$using:node.VHDName
                    $mountpath = $using:node.MountDir+$($using:VMInfo.VMName)

                    Write-verbose "Mounting image [$imagepath] to [$mountpath]"
                    Mount-WindowsImage -ImagePath $imagepath -Index 1 -path $mountpath


                }
                TestScript = {
                    if ((get-vm | where {$_.Name -eq $($using:VMInfo.VMName)}) -ne $null) {
                        return $true
                    }

                    return ((Test-Path (($using:node.MountDir+$($using:VMInfo.VMName)) + "\Windows")))
                }
                GetScript = {
                    return @{ result = Test-Path (($using:node.MountDir+$using:vminfo.vmname) + "\Windows") }
                }
            }

            Script "CustomizeUnattend_$($VMInfo.VMName)"
            {                                      
                SetScript = {
                    $unattendfile = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Interfaces>
{0}
            </Interfaces>
        </component>
         <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Interfaces>
                <Interface wcm:action="add">
                    <DNSServerSearchOrder>
{1}
                    </DNSServerSearchOrder>
                    <Identifier>Ethernet</Identifier>
                </Interface>
            </Interfaces>
        </component>
        <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Identification>
                <Credentials>
                    <Domain>{3}</Domain>
                    <Password>{5}</Password>
                    <Username>{4}</Username>
                </Credentials>
                <JoinDomain>{3}</JoinDomain>
            </Identification>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>{2}</ComputerName>
            {7}
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>{6}</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
                <DomainAccounts>
                    <DomainAccountList wcm:action="add">
                        <DomainAccount wcm:action="add">
                            <Name>{4}</Name>
                            <Group>Administrators</Group>
                        </DomainAccount>
                        <Domain>{3}</Domain>
                    </DomainAccountList>
                </DomainAccounts>
            </UserAccounts>
            <TimeZone>Pacific Standard Time</TimeZone>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
            </OOBE>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserLocale>en-US</UserLocale>
            <SystemLocale>en-US</SystemLocale>
            <InputLocale>0409:00000409</InputLocale>
            <UILanguage>en-US</UILanguage>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

                    $interfacetemplate = @"
                 <Interface wcm:action="add">
                    <Ipv4Settings>
                        <DhcpEnabled>false</DhcpEnabled>
                    </Ipv4Settings>
                    <Identifier>Ethernet</Identifier>
                    <UnicastIpAddresses>
                        <IpAddress wcm:action="add" wcm:keyValue="1">{0}/{1}</IpAddress>
                    </UnicastIpAddresses>
                    <Routes>
                        <Route wcm:action="add">
                            <Identifier>0</Identifier>
                            <Prefix>0.0.0.0/0</Prefix>
                            <Metric>20</Metric>
                            <NextHopAddress>{2}</NextHopAddress>
                        </Route>
                    </Routes>
                </Interface>
"@

                    $dstfile = $using:node.MountDir+$($Using:VMInfo.VMName)+"\unattend.xml"

                    $alldns = ""
                    $count = 1
                    $allnics = ""

                    foreach ($nic in $using:vminfo.Nics) {
                        foreach ($ln in $using:node.LogicalNetworks) {
                            if ($ln.Name -eq $nic.LogicalNetwork) {
                                break
                            }
                        }

                        #TODO: Right now assumes there is one subnet.  Add code to find correct subnet given IP.
                    
                        $sp = $ln.subnets[0].AddressPrefix.Split("/")
                        $mask = $sp[1]

                        #TODO: Add in custom routes since multi-homed VMs will need them.
                    
                        $gateway = $ln.subnets[0].gateways[0]
                        $allnics += $interfacetemplate -f $nic.IPAddress, $mask, $gateway

                        foreach ($dns in $ln.subnets[0].DNS) {
                            $alldns += '<IpAddress wcm:action="add" wcm:keyValue="{1}">{0}</IpAddress>' -f $dns, $count++
                        }
                    }
                    
                    $key = ""
                    if ($($Using:node.productkey) -ne "" ) {
                        $key = "<ProductKey>$($Using:node.productkey)</ProductKey>"
                    }
                    $finalUnattend = ($unattendfile -f $allnics, $alldns, $($Using:vminfo.vmname), $($Using:node.fqdn), $($Using:node.DomainJoinUsername), $($Using:node.DomainJoinPassword), $($Using:node.LocalAdminPassword), $key )
                    write-verbose $finalunattend
                    set-content -value $finalUnattend -path $dstfile
                }
                TestScript = {
                    if ((get-vm | where {$_.Name -eq $($using:VMInfo.VMName)}) -ne $null) {
                        return $true
                    }
                    return $false
                }
                GetScript = {
                    return @{ result = DisMount-WindowsImage -Save -path ($using:node.MountDir+$using:vminfo.vmname) }
                }
            } 

            Script "DisMountImage_$($VMInfo.VMName)"
            {                                      
                SetScript = {
                    $mountpath = $using:node.MountDir+$($using:VMInfo.VMName)

                    Write-verbose "Dis-Mounting image [$mountpath]"
                    DisMount-WindowsImage -Save -path $mountpath
                }
                TestScript = {
                    if ((get-vm | where {$_.Name -eq $($using:VMInfo.VMName)}) -ne $null) {
                        return $true
                    }
                    $exist = (Test-Path ($using:node.MountDir+$using:vminfo.vmname+"\Windows")) -eq $False

                    return $exist
                }
                GetScript = {
                    return @{ result = DisMount-WindowsImage -Save -path ($using:node.MountDir+$using:vminfo.vmname) }
                }
            }          
            
            Script "NewVM_$($VMInfo.VMName)"
            {                                      
                SetScript = {
                    $vminfo = $using:VMInfo
                    write-verbose "Creating new VM"
                    New-VM -Generation 2 -Name $VMInfo.VMName -Path ($using:node.VMLocation+"\"+$($VMInfo.VMName)) -MemoryStartupBytes $VMInfo.VMMemory -VHDPath ($using:node.VMLocation+"\"+$($using:VMInfo.VMName)+"\"+$using:node.VHDName) -SwitchName $using:node.vSwitchName
                    write-verbose "Setting processor count"
                    set-vm -Name $VMInfo.VMName -processorcount 8
                    write-verbose "renaming default network adapter"
                    get-vmnetworkadapter -VMName $VMInfo.VMName | rename-vmnetworkadapter -newname $using:VMInfo.Nics[0].Name
                    write-verbose "Adding $($VMInfo.Nics.Count-1) additional adapters"
                    
                    for ($i = 1; $i -lt $VMInfo.Nics.Count; i++) {
                        write-verbose "Adding adapter $($VMInfo.Nics[$i].Name)"
                        Add-VMNetworkAdapter -VMName $VMInfo.VMName -SwitchName $using:node.vSwitchName -Name $VMInfo.Nics[$i].Name -StaticMacAddress $VMInfo.Nics[$i].MACAddress
                    }
                    write-verbose "Finished creating VM"
                }
                TestScript = {
                    if ((get-vm | where {$_.Name -eq $($using:VMInfo.VMName)}) -ne $null) {
                        return $true
                    }
                    return $false
                }
                GetScript = {
                    return @{ result = DisMount-WindowsImage -Save -path ($using:node.MountDir+$using:vminfo.vmname) }
                }
            }
            foreach ($nic in $vminfo.Nics) {
                Script "SetPortAndProfile_$($VMInfo.VMName)_$($nic.IPAddress)"
                {                                      
                    SetScript = {
                        . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1"

                        $nic = $using:nic
                        $lns = $using:node.logicalnetworks
                        $vminfo = $using:vminfo

                        write-verbose "finding logical network"

                        foreach ($lntest in $lns) {
                            if ($lntest.Name -eq $nic.LogicalNetwork) {
                                write-verbose "found logical network"
                                $ln = $lntest 
                            }
                        }

                        write-verbose "Setting VLAN [$($vminfo.VMname)] [$($nic.Name)] [$($ln.subnets[0].vlanid)]"

                        #todo: assumes one subnet.
                        Set-VMNetworkAdapterIsolation -vmname $vminfo.VMname -vmnetworkadaptername $nic.Name -AllowUntaggedTraffic $true -IsolationMode VLAN -defaultisolationid $ln.subnets[0].vlanid
                        write-verbose "Setting port profile"
                        Set-PortProfileId -ResourceID $nic.portprofileid -vmname $using:vminfo.vmName -computername localhost -ProfileData $nic.portprofiledata -Force
                        write-verbose "completed setport"
                    }
                    TestScript = {
                        $vlans = Get-VMNetworkAdapterIsolation -VMName $using:vminfo.VMName -vmnetworkadaptername $nic.Name
                        if($vlans -eq $null) {
                            return $false
                        } 
                        else {
                            foreach ($ln in $using:node.LogicalNetworks) {

                                if ($ln.Name -eq $using:nic.LogicalNetwork) {
                                    break
                                }
                            }

                            if(($vlans[0] -eq $null) -or ($vlans[0].defaultisolationid -eq $null) -or ($vlans[0].defaultisolationid -ne $ln.subnets[0].vlanid)) {
                                return $false
                            } 
                            return $true
                        }
                    }
                    GetScript = {
                        return @{ result = (Get-VMNetworkAdapterVlan -VMName $using:vminfo.VMName)[0] }
                    }
                }
            }
            Script "StartVM_$($VMInfo.VMName)"
            {                                      
                SetScript = {
                    Get-VM -Name $using:vminfo.VMName | Start-VM
                }
                TestScript = {
                    $vm = Get-VM -Name $using:vminfo.VMName | Select-Object -First 1 
                    if($vm -ne $null -and $vm[0].State -eq "Running") {
                        return $true
                    }

                    return $false
                }
                GetScript = {
                    return @{ result = (Get-VM -Name $using:vminfo.VMName)[0] }
                }
            }
        }
    }
}

Configuration ConfigureNetworkControllerVMs
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.Role -eq "NetworkController"}.NodeName
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        Script DisableIPv6
        {
            setscript = {
                reg add hklm\system\currentcontrolset\services\tcpip6\parameters /v DisabledComponents /t REG_DWORD /d 255 /f
            }
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        Script SetWinRmEnvelope
        {                                      
            SetScript = {
                write-verbose "Setting WinRM Envelope size."
                Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 5000
            }
            TestScript = {
                return ((Get-Item WSMan:\localhost\MaxEnvelopeSizekb).Value -ge 5000)
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        Script SetAllHostsTrusted
        {                                      
            SetScript = {
                write-verbose "Trusting all hosts."
                set-item wsman:\localhost\Client\TrustedHosts -value * -Force
            }
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        Script Firewall-SMB
        {                                      
            SetScript = {
                Enable-netfirewallrule "FPS-SMB-In-TCP"
                Enable-netfirewallrule "FPS-SMB-Out-TCP"
            }
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }  

        Script Firewall-REST
        {                                      
            SetScript = {
                new-netfirewallrule -Name "Firewall-REST" -DisplayName "Network Controller Host Agent REST" -Group "NcHostAgent" -Enabled True -direction Inbound -LocalPort 80 -action Allow -protocol "TCP"
            }
            TestScript = {
                return (get-netfirewallrule | where {$_.Name -eq "Firewall-REST"}) -ne $null
            }
            GetScript = {
                return @{ result = $true }
            }
        }        
        Script Firewall-OVSDB
        {                                      
            SetScript = {
                new-netfirewallrule -Name "Firewall-OVSDB" -DisplayName "Network Controller Host Agent OVSDB" -Group "NcHostAgent" -Enabled True -direction Inbound -LocalPort 6640 -action Allow -protocol "TCP"
            }
            TestScript = {
                return (get-netfirewallrule | where {$_.Name -eq "Firewall-OVSDB"}) -ne $null
            }
            GetScript = {
                return @{ result = $true }
            }
        }        

        Script AddNetworkControllerRole
        {                                      
            SetScript = {
                add-windowsfeature NetworkController -IncludeAllSubFeature -IncludeManagementTools -Restart
            }
            TestScript = {
                $status = get-windowsfeature NetworkController
                return ($status.Installed)
            }
            GetScript = {
                return @{ result = $true }
            }
        } 
        Script ForceRestart
        {                                      
            SetScript = {
                Restart-computer -Force -Confirm:$false -AsJob
            }
            TestScript = {
                $nc = try { get-networkcontroller } catch { }
                return ($nc -ne $null)
            }
            GetScript = {
                return @{ result = $true }
            }
        } 

    }
}

Configuration CreateControllerCert
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.ServiceFabricRingMembers -ne $null}.NodeName
    {
        Script CreateRESTCert
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"

                $nccertSubject = "$($using:node.NetworkControllerRestName)"
                $nccertname = $nccertSubject

                write-verbose "Generating self signed cert for $($using:node.NetworkControllerRestName)."
                GenerateSelfSignedCertificate $nccertSubject

                $cn = "$($nccertSubject)".ToUpper()
                $cert = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                GivePermissionToNetworkService $Cert[0]
                write-verbose "Exporting certificate to: [c:\$nccertname]"
                [System.io.file]::WriteAllBytes("c:\$nccertname.pfx", $cert.Export("PFX", "secret"))
                Export-Certificate -Type CERT -FilePath "c:\$nccertname" -cert $cert
                write-verbose "Adding to local machine store."
                AddCertToLocalMachineStore "c:\$nccertname" "Root"
            } 
            TestScript = {
                $cn = "$($using:node.NetworkControllerRestName)".ToUpper()
                
                write-verbose ("Checking network controller cert configuration.")
                $cert = get-childitem "Cert:\localmachine\my" -ErrorAction Ignore | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                if ($cert -eq $null) {
                    write-verbose ("cert:\localmachine\my cert not found.")
                    return $false
                }
                
                $nccertname = "$($using:node.NetworkControllerRestName).pfx"
                write-verbose ("cert:\localmachine\my cert found.  Checking for c:\$nccertname.")
                $certfile = get-childitem "c:\$nccertname"  -ErrorAction Ignore
                if ($certfile -eq $null) {
                    write-verbose ("$nccertname not found.")
                    return $false
                }
                
                write-verbose ("$nccertname found.  Checking for cert in cert:\localmachine\root.")
                $cert = get-childitem "Cert:\localmachine\root\$($cert.thumbprint)" -ErrorAction Ignore
                if ($cert -eq $null) {
                    write-verbose ("Cert in cert:\localmachine\root not found.")
                    return $false
                }
                write-verbose ("Cert found in cert:\localmachine\root.  Cert creation not needed.")
                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script CreateNCVmCerts
        {
            SetScript = {
                write-verbose ("CreateNCVmCerts")
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"
                
                $allnodes = $using:AllNodes
                $hyperVHosts = $allnodes.Where{$_.Role -eq "NetworkController"}

                foreach ($host in $hyperVHosts) {
                    $cn = "$($host.nodename).$($host.FQDN)".ToUpper()
                    $nccertname = "$($using:host.NetworkControllerRestName)"
                    $certName = "$($host.NodeName).$($nccertname)"
                    
                    write-verbose ("Creating Cert $($cn)")
                    $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                    if ($cert -eq $null) {
                        write-verbose ("Generating Certificate...")
                        GenerateSelfSignedCertificate $cn
                        $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                    }

                    $certPwd = $host.HostPassword
                    write-verbose "Exporting PFX certificate to: [c:\$nccertname]"
                    [System.io.file]::WriteAllBytes("c:\$($certName).pfx", $cert.Export("PFX", $certPwd))
                    write-verbose ("Export CER")
                    Export-Certificate -Type CERT -FilePath "c:\$($certName)" -cert $cert
                    del cert:\localmachine\my\$($cert.Thumbprint)
                }
            } 
            TestScript = {
                write-verbose ("CreateNCVmCerts test.")
                
                $allnodes = $using:AllNodes
                $hyperVHosts = $allnodes.Where{$_.Role -eq "NetworkController"}
                
                foreach ($host in $hyperVHosts) {
                    $nccertname = "$($using:host.NetworkControllerRestName)"
                    $certName = "$($host.NodeName).$($nccertname)"
                    
                    write-verbose ("Checking for c:\$($certName).pfx")
                    $certfile = get-childitem "c:\$($certName).pfx"  -ErrorAction Ignore
                    if ($certfile -eq $null) {
                        write-verbose ("c:\$($certName).pfx not found.")
                        return $false
                    }
                    
                    write-verbose ("Checking for c:\$($certName)")
                    $certfile = get-childitem "c:\$($certName)"  -ErrorAction Ignore
                    if ($certfile -eq $null) {
                        write-verbose ("c:\$($certName) not found.")
                        return $false
                    }
                    write-verbose ("Cert files found.  Cert creation not needed.")
                }

                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        
        Script CreateHostCerts
        {
            SetScript = {
                write-verbose ("CreateHostCerts")
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"
                
                $allnodes = $using:AllNodes
                $hyperVHosts = $allnodes.Where{$_.Role -eq "HyperVHost"}

                foreach ($host in $hyperVHosts) {
                    $cn = "$($host.nodename).$($host.FQDN)".ToUpper()
                    write-verbose ("Creating Cert $($cn)")
                    $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                    if ($cert -eq $null) {
                        write-verbose ("Generating Certificate...")
                        GenerateSelfSignedCertificate $cn
                        $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                    }

                    $certPwd = $host.HostPassword
                    $certPwdSec = ConvertTo-SecureString -String $certPwd -Force -AsPlainText
                    write-verbose ("Export PFX")
                    Export-PfxCertificate -FilePath "c:\$($cn).pfx" -Force -Cert $cert -Password $certPwdSec
                    write-verbose ("Export CER")
                    Export-Certificate -Type CERT -FilePath "c:\$($cn).cer" -cert $cert
                    del cert:\localmachine\my\$($cert.Thumbprint)
                }
            } 
            TestScript = {
                write-verbose ("CreateHostCerts test.")
                
                $allnodes = $using:AllNodes
                $hyperVHosts = $allnodes.Where{$_.Role -eq "HyperVHost"}
                
                foreach ($host in $hyperVHosts) {
                    $certName = "$($host.nodename).$($host.FQDN)".ToUpper()
                    
                    write-verbose ("Checking for c:\$($certName).pfx")
                    $certfile = get-childitem "c:\$($certName).pfx"  -ErrorAction Ignore
                    if ($certfile -eq $null) {
                        write-verbose ("c:\$($certName).pfx not found.")
                        return $false
                    }
                    
                    write-verbose ("Checking for c:\$($certName).cer")
                    $certfile = get-childitem "c:\$($certName).cer"  -ErrorAction Ignore
                    if ($certfile -eq $null) {
                        write-verbose ("c:\$($certName).cer not found.")
                        return $false
                    }
                    write-verbose ("Cert files found.  Cert creation not needed.")
                }

                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}
Configuration InstallControllerCerts
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.Role -eq "NetworkController"}.NodeName
    {
        Script InstallMyCerts
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"

                $certpath = "$($using:node.installsrcdir)\$($using:node.certfolder)"
                $nccertname = "$($using:node.NetworkControllerRestName)"

                write-verbose "Adding $($nccertname) to local machine store from $($certpath)"
                AddCertToLocalMachineStore "$certpath\$nccertname.pfx" "My" "secret"
                AddCertToLocalMachineStore "$certpath\$nccertname.pfx" "Root" "secret"
                
                $cn = "$($using:node.NetworkControllerRestName)".ToUpper()
                write-verbose "Getting Cert $($cn)"
                $cert = get-childitem "Cert:\localmachine\My" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}    
                if ($cert -eq $null) {
                    write-error ("Cert $cn in cert:\localmachine\My not found.")
                }
                write-verbose "Giving Permission to Network Service $($cert.Thumbprint)"
                GivePermissionToNetworkService $cert
                
                write-verbose "Getting Cert $($cn)"
                $cert = get-childitem "Cert:\localmachine\Root" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}    
                if ($cert -eq $null) {
                    write-error ("Cert $cn in cert:\localmachine\Root not found.")
                }
                write-verbose "Giving Permission to Network Service $($cert.Thumbprint)"
                GivePermissionToNetworkService $cert

                $ncVmCertname = "$($using:node.NodeName).$($nccertname)"
                $certPwd = "$($using:node.HostPassword)"
                write-verbose "Adding $($ncVmCertname) to local machine store with Password $($certPwd)"
                AddCertToLocalMachineStore "$certpath\$ncVmCertname.pfx" "My" $certPwd
            } 
            TestScript = {
                $cn = "$($using:node.NetworkControllerRestName)".ToUpper()

                write-verbose ("Checking for cert $($cn) in cert:\localmachine\my")
                $cert = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                if ($cert -eq $null) {
                    write-verbose ("Cert in cert:\localmachine\my not found.")
                    return $false
                }
                
                $cn = "$($using:node.nodename).$($using:node.fqdn)".ToUpper()

                write-verbose ("Checking for cert $($cn) in cert:\localmachine\my")
                $cert = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                if ($cert -eq $null) {
                    write-verbose ("Cert in cert:\localmachine\my not found.")
                    return $false
                }
                
                write-verbose ("Certs found in cert:\localmachine\my.  Cert creation not needed.")
                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        Script InstallRootCerts
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"

                $certpath = "$($using:node.installsrcdir)\$($using:node.certfolder)"
                $nccertname = "$($using:node.NetworkControllerRestName)"

                foreach ($othernode in $using:allnodes) {
                    if ($othernode.Role -eq "NetworkController") {
                       # if ($othernode.NodeName -ne $using:node.nodename) {
                            $cn = "$($othernode.nodename).$($using:node.fqdn)".ToUpper()

                            write-verbose ("Checking $cn in cert:\localmachine\root")
                            $cert = get-childitem "Cert:\localmachine\root" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}

                            if ($cert -eq $null) {
                                $certfullpath = "$certpath\$($othernode.nodename).$($nccertname).pfx"
                                write-verbose "Adding $($cn) cert to root store from $certfullpath"
                                $certPwd = $using:node.HostPassword
                                AddCertToLocalMachineStore $certfullpath "Root" $certPwd
                            }
                       # } 
                    }
                }
            } 
            TestScript = {

                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Configuration EnableNCTracing
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.Role -eq "NetworkController"}.NodeName
    {
        Script StartNCTracing
        {
            SetScript = {
                write-verbose ("Set StartNCTracing")
                $date = Get-Date
                $tracefile = "c:\networktrace-$($date.Year)-$($date.Month)-$($date.Day)-$($date.Hour)-$($date.Minute)-$($date.Second)-$($date.Millisecond).etl"
                cmd /c "netsh trace start globallevel=5 provider={80355850-c8ed-4336-ade2-6595f9ca821d} provider={22f5dddb-329e-4f87-a876-56471886ba81} provider={d2a364bd-0c3f-428a-a752-db983861673f} provider={d304a717-2718-4580-a155-458f8ac12091} provider={90399F0C-AE84-49AF-B46A-19079B77B6B8} provider={6c2350f8-f827-4b74-ad0c-714a92e22576} provider={ea2e4e95-2b14-462d-bb78-dee94170804f} provider={d79293d5-78ba-4687-8cef-4492f1e3abf9} provider={77494040-1F07-499D-8553-03DB545C031C} provider={5C8E3932-E6DF-403D-A3A3-EC6BF6D7977D} provider={A1EA8728-5700-499E-8FDD-64954D8D3578} provider={8B0C6DD7-B6D8-48C2-B83E-AFCBBA5B57E8} provider={C755849B-CF02-4F21-B82B-D92D26A91069} provider={f1107188-2054-4758-8a89-8fe5c661590f} provider={93e14ac2-289b-45b7-b654-db51e293bf52} provider={eefaa5fb-5f0b-46a5-a3f7-0e06bc972c30} report=di tracefile=$tracefile overwrite=yes"
            } 
            TestScript = {
                write-verbose ("Test StartNCTracing")
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Configuration DisableNCTracing
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.Role -eq "NetworkController"}.NodeName
    {
        Script StopNCTracing
        {
            SetScript = {
                cmd /c "netsh trace stop"
            } 
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Configuration CopyToolsAndCerts
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    
    Node $AllNodes.Where{$_.Role -in @("HyperVHost", "NetworkController")}.NodeName
    {
        if (![String]::IsNullOrEmpty($node.ToolsSrcLocation)) {
            File ToolsDirectory
            {
                Type = "Directory"
                Ensure = "Present"
                Force = $True
                Recurse = $True
                MatchSource = $True
                SourcePath = $node.InstallSrcDir+"\"+$node.ToolsSrcLocation
                DestinationPath = $node.ToolsLocation
            }  

            File CertHelpersScript
            {
                Type = "File"
                Ensure = "Present"
                Force = $True
                MatchSource = $True
                SourcePath = $node.InstallSrcDir+"\Scripts\CertHelpers.ps1"
                DestinationPath = $node.ToolsLocation+"\CertHelpers.ps1"
            }

            File RestWrappersScript
            {
                Type = "File"
                Ensure = "Present"
                Force = $True
                MatchSource = $True
                SourcePath = $node.InstallSrcDir+"\Scripts\NetworkControllerRESTWrappers.ps1"
                DestinationPath = $node.ToolsLocation+"\NetworkControllerRESTWrappers.ps1"
            }            
        }

        if (![String]::IsNullOrEmpty($node.CertFolder)) {
            File CertsDirectory
            {
                Type = "Directory"
                Ensure = "Present"
                Force = $True
                Recurse = $True
                MatchSource = $True
                SourcePath = $node.InstallSrcDir+"\"+$node.CertFolder
                DestinationPath = $env:systemdrive+"\"+$node.CertFolder
            }        
        }
    }
}

Configuration ConfigureNetworkControllerCluster
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.ServiceFabricRingMembers -ne $null}.NodeName
    {
        Script CreateControllerCluster
        {                                      
            SetScript = {
                write-verbose ("Set CreateControllerCluster")
                $pwd = ConvertTo-SecureString $using:node.NCClusterPassword -AsPlainText -Force; 
                $cred = New-Object System.Management.Automation.PSCredential $using:node.NCClusterUsername, $pwd;
                
                $nc = try { get-networkcontroller -Credential $cred } catch { }
                if ($nc -ne $null) {
                    write-verbose ("Attempting cleanup of network controller.")
                    $start = Get-Date
                    uninstall-networkcontroller -Credential $cred -Force
                    $end = Get-Date
                    $span = $end-$start
                    write-verbose "Cleanup of network controller tooks $($span.totalminutes) minutes."
                }
                $ncc = try { get-networkcontrollercluster -Credential $cred } catch { }
                if ($ncc -ne $null) {
                    write-verbose ("Attempting cleanup of network controller cluster.")
                    $start = Get-Date
                    uninstall-networkcontrollercluster -Credential $cred -Force
                    $end = Get-Date
                    $span = $end-$start
                    write-verbose "Cleanup of network controller cluster tooks $($span.totalminutes) minutes."
                }
               
                $nodes = @()
                foreach ($server in $using:node.ServiceFabricRingMembers) {
                    write-verbose ("Clearing existing node content.")
                    try { Invoke-Command -ScriptBlock { clear-networkcontrollernodecontent -Force } -ComputerName $server -Credential $cred } catch { }

                    $cn = "$server.$($using:node.FQDN)".ToUpper()
                    $cert = get-childitem "Cert:\localmachine\root" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                    if ($cert -eq $null) {
                        write-error "Certificate not found for $cn in Root store" 
                    }
                    
                    write-verbose ("Adding node: {0}.{1}" -f $server, $using:node.FQDN)
                    $nodes += New-NetworkControllerNodeObject -Name $server -Server ($server+"."+$using:node.FQDN) -FaultDomain ("fd:/"+$server) -RestInterface "Ethernet" -NodeCertificate $cert -verbose                    
                }

                $mgmtSecurityGroupName = $using:node.mgmtsecuritygroupname
                $clientSecurityGroupName = $using:node.clientsecuritygroupname
                
                $cn = "$($using:node.NetworkControllerRestName)".ToUpper()
                $cert = get-childitem "Cert:\localmachine\root" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")} | Select-Object -First 1 
                
                write-verbose "Using cert with Subject $($cert.Subject) $($cert.thumbprint)"
                
                write-verbose "nodes $($nodes) "
                write-verbose "mgmtSecurityGroupName $($mgmtSecurityGroupName) "
                $start = Get-Date
                if ([string]::isnullorempty($mgmtSecurityGroupName)) {
                    write-verbose "Install-NetworkControllerCluster X509 "
                    Install-NetworkControllerCluster -Node $nodes -ClusterAuthentication X509 -credentialencryptioncertificate $cert -Credential $cred -force -verbose
                } else {
                    write-verbose "Install-NetworkControllerCluster Kerberos "
                    Install-NetworkControllerCluster -Node $nodes -ClusterAuthentication Kerberos -ManagementSecurityGroup $mgmtSecurityGroupName -credentialencryptioncertificate $cert -Force -Verbose
                }
                $end = Get-Date
                $span = $end-$start
                write-verbose "Installation of network controller cluster tooks $($span.totalminutes) minutes."

                if ($using:node.UseHttp -eq $true) {
                    write-verbose "Use HTTP"
                    [Microsoft.Windows.Networking.NetworkController.PowerShell.InstallNetworkControllerCommand]::UseHttpForRest=$true
                }

                write-verbose ("Install-networkcontroller")
                write-verbose ("REST IP is: $($using:node.NetworkControllerRestIP)/$($using:node.NetworkControllerRestIPMask)")
                $start = Get-Date
                if ([string]::isnullorempty($clientSecurityGroupName)) {
                    try { Install-NetworkController -ErrorAction Ignore -Node $nodes -ClientAuthentication None -ServerCertificate $cert  -Credential $cred -Force -Verbose -restipaddress "$($using:node.NetworkControllerRestIP)/$($using:node.NetworkControllerRestIPMask)" } catch { Write-Verbose "Install-NetworkController threw Exception: $($_.Exception.Message)"}
                } else {
                    Install-NetworkController -Node $nodes -ClientAuthentication Kerberos -ClientSecurityGroup $clientSecurityGroupName -ServerCertificate $cert  -Force -Verbose -restipaddress "$($using:node.NetworkControllerRestIP)/$($using:node.NetworkControllerRestIPMask)"
                }
                $end = Get-Date
                $span = $end-$start
                write-verbose "Installation of network controller tooks $($span.totalminutes) minutes."             
                write-verbose ("Network controller setup is complete.")

                Write-Verbose "Ensure network controller services are ready."
                
                $totalRetries = 60  # Give 10 minutes ($totalRetries * $interval / 60) for the validations below to timeout
                $currentRetries = 0
                $interval = 10  #seconds
                
                do {
                    $servicesReady = $true
                    try {
                        Write-Verbose "Current Attempt: $currentRetries"
                        Write-Verbose "Connecting to service fabric cluster"
                        Connect-ServiceFabricCluster
                        Write-Verbose "Getting all network controller services"
                        $services = Get-ServiceFabricApplication fabric:/NetworkController | Get-ServiceFabricService  
                    
                        foreach ($service in $services)
                        {
                            if ($service.ServiceStatus -ne [System.Fabric.Query.ServiceStatus]::Active -or $service.HealthState -ne [System.Fabric.Health.HealthState]::Ok) {
                                $servicesReady = $false
                                Write-Verbose "The service ($($service.ServiceTypeName)) is not in Active status or its health state is not OK."
                            }
                            
                            Write-Verbose "Getting replicas for service $($service.ServiceTypeName) and checking their status."
                            $replicas = Get-ServiceFabricPartition $service.ServiceName | Get-ServiceFabricReplica
                            foreach ($replica in $replicas) {
                                if ($replica.ReplicaStatus -ne [System.Fabric.Query.ServiceReplicaStatus]::Ready) {
                                    Write-Verbose "Replica ($($replica.ReplicaId)) of service ($($service.ServiceTypeName)) is not in Ready state. Current state: $($replica.ReplicaStatus)."
                                    $servicesReady = $false
                                }
                            }
                            
                            if ($service.ServiceKind -eq [System.Fabric.Query.ServiceKind]::Stateful) {
                                Write-Verbose "Checking if the Primary replica is available for service $($service.ServiceTypeName) since it is stateful service."
                                $primaryReplica = $replicas | ? { $_.ReplicaRole.ToString() -eq "Primary" }
                                if (-not $primaryReplica) {
                                    $servicesReady = $false
                                    Write-Verbose "The Primary replica is NOT available for service $($service.ServiceTypeName)."
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Warning: Failed to check the status of network controller services. Will retry in $interval seconds"
                        Write-Verbose "Exception caught: $_"
                        $servicesReady = $false
                    }

                    if($servicesReady) {
                        break
                    }

                    $currentRetries++
                    Start-Sleep -Seconds $interval
                } while ($currentRetries -le $totalRetries)

                if($servicesReady -eq $false) {
                    throw "Network Controller services are not ready"
                }
                
                Start-Sleep -Seconds 30
                Write-Verbose "Network Controller services are ready (after $currentRetries validations)!"                 
            }
            TestScript = {
                write-verbose ("Checking network controller configuration.")
                $pwd = ConvertTo-SecureString $using:node.NCClusterPassword -AsPlainText -Force; 
                $cred = New-Object System.Management.Automation.PSCredential $using:node.NCClusterUsername, $pwd; 

                $nc = try { get-networkcontroller -credential $cred } catch { }

                if ($nc -ne $null)
                {
                    write-verbose ("Network controller found, checking for REST response.")
                    $credential = $null
                    $response = $null
                    try {
                        if ([String]::isnullorempty($using:node.NCClusterUserName) -eq $false) {
                            $password =  convertto-securestring $using:node.NCClusterPassword -asplaintext -force
                            $credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $using:node.NCClusterUserName,$password
                            $response = invoke-webrequest "https://$($using:node.NetworkControllerRestName)/Networking/v1/LogicalNetworks" -UseBasicParsing -credential $credential -ErrorAction SilentlyContinue
                        } else {
                           $response = invoke-webrequest "https://$($using:node.NetworkControllerRestName)/Networking/v1/LogicalNetworks" -UseBasicParsing -ErrorAction SilentlyContinue
                        }
                    }
                    catch {}
                    if ($response -eq $null) {
                        return $false;
                    }
                    return ($response.StatusCode -eq 200)
                }
                write-verbose ("Network controller not configured yet.")
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        Script CreateNCHostCredentials
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
               
                $hostcred = New-NCCredential -ResourceId $using:node.HostCredentialResourceId -Username $using:node.HostUsername -Password $using:node.HostPassword
            } 
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                ipconfig /flushdns
                $ncnotactive = $true
                $attempts = 10
                while ($ncnotactive) {
                    write-verbose "Checking that the controller is up and whether or not it has credentials yet."
                    sleep 10
                    $response = $null
                    try { 
                        if (![String]::isnullorempty($using:node.NCClusterUserName)) {
                            $securepass =  convertto-securestring $using:node.NCClusterPassword -asplaintext -force
                            $credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $using:node.NCClusterUserName,$securepass
                            $response = invoke-webrequest https://$($using:node.NetworkControllerRestName)/Networking/v1/Credentials -usebasicparsing  -ErrorAction SilentlyContinue -credential $credential 
                        } else {
                            $response = invoke-webrequest https://$($using:node.NetworkControllerRestName)/Networking/v1/Credentials -usebasicparsing  -ErrorAction SilentlyContinue
                        }
                    } catch { }
                    $ncnotactive = ($response -eq $null)
                    $attempts -= 1;
                    if($attempts -eq 0) { write-verbose "Giving up after 10 tries."; return $false }
                }
                write-verbose "Controller is UP."

                $obj = Get-NCCredential -ResourceId $using:node.HostCredentialResourceId
                return $obj -ne $null
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script CreateNCCredentials
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword

                $cn = "$($using:node.NetworkControllerRestName)".ToUpper()
                $cert = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                write-verbose "got cert with cn=$cn"
                $hostcred = New-NCCredential -ResourceId $using:node.NCCredentialResourceId -Thumbprint $cert.Thumbprint
            } 
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $obj = Get-NCCredential -ResourceId $using:node.NCCredentialResourceId
                return $obj -ne $null  
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        foreach ($ln in $node.LogicalNetworks) {
            Script "CreateLogicalNetwork_$($ln.Name)"
            {
                SetScript = {
                    . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                    $subnets = @()
                    foreach ($subnet in $using:ln.Subnets) {
                        if ($subnet.IsPublic) {
                            $subnets += New-NCLogicalNetworkSubnet -AddressPrefix $subnet.AddressPrefix -VLANId $subnet.vlanid -DNSServers $subnet.DNS -defaultGateway $subnet.Gateways -IsPublic
                        } else {
                            $subnets += New-NCLogicalNetworkSubnet -AddressPrefix $subnet.AddressPrefix -VLANId $subnet.vlanid -DNSServers $subnet.DNS -defaultGateway $subnet.Gateways
                        }
                    }

                    #
                    for($attempt = 3; $attempt -ne 0; $attempt--)
                    {
                        if ($ln.NetworkVirtualization) {
                            $newln = New-NCLogicalNetwork -resourceId $using:ln.ResourceId -LogicalNetworkSubnets $subnets -EnableNetworkVirtualization 
                        } 
                        else
                        {
                            $newln = New-NCLogicalNetwork -resourceId $using:ln.ResourceId -LogicalNetworkSubnets $subnets
                        }
                        
                        if($newln -eq $null)
                        {
                            Write-Verbose "Logical network $($ln.Name) is not created on network controller. Will retry in 30 seconds."
                            Start-Sleep -Seconds 30
                        }
                        else
                        {
                            Write-Verbose "Logical network $($ln.Name) is created on network controller."
                            break;
                        }
                    }

                    $i = 0
                    foreach ($subnet in $using:ln.Subnets) {
                        $ippool = New-NCIPPool -LogicalNetworkSubnet $newln.properties.subnets[$i++]  -StartIPAddress $subnet.PoolStart -EndIPAddress $subnet.PoolEnd -DNSServers $subnet.DNS -DefaultGateways $subnet.Gateways
                    }
                } 
                TestScript = {
                    . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                    $obj = Get-NCLogicalNetwork -ResourceId $using:ln.ResourceId
                    return $obj -ne $null
                }
                GetScript = {
                    return @{ result = $true }
                }
            }
        }
        Script ConfigureSLBManager
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $LogicalNetworks = Get-NCLogicalNetwork #-resourceId $using:node.VIPLogicalNetworkResourceId

                $vipippools = @()
                $slbmip = ""

                write-verbose "Finding public subnets to use as VIPs."

                foreach ($ln in $logicalNetworks) {
                    write-verbose "Checking $($ln.resourceid)."
                    foreach ($subnet in $ln.properties.subnets) {
                        write-verbose "subnet $($subnet.properties.addressprefix)."
                        if ($subnet.properties.isPublic -eq "True") {
                            write-verbose "Found public subnet."
                            $vipippools += $subnet.properties.ippools
                            if ($slbmip -eq "") {
                                $slbmip = $subnet.properties.ippools[0].properties.startIpAddress
                                write-verbose "SLBMVIP is $slbmip."
                            }
                        }
                    }
                }

                $lbconfig = set-ncloadbalancermanager -IPAddress $slbmip -VIPIPPools $vipippools -OutboundNatIPExemptions @("$slbmip/32")

                $pwd = ConvertTo-SecureString $using:node.NCClusterPassword -AsPlainText -Force
                $cred = New-Object System.Management.Automation.PSCredential $using:node.NCClusterUsername, $pwd

                #write-verbose "Resetting SLBM VIP [$slbmip] prefix to /32 on $($using:node.ServiceFabricRingMembers)"
                
                Invoke-Command -ComputerName $using:node.ServiceFabricRingMembers -credential $cred -Argumentlist $slbmip -ScriptBlock { 
                    param($slbmip2)

                    $ip = $null

                    while ($ip -eq $null) 
                    {
                        write-host "Waiting for SLBM VIP [$slbmip2] to be created"
                        sleep 1
                        $ip = get-netipaddress $slbmip2 -ErrorAction Ignore
                    }
                    write-host "Forcing SLBM VIP prefix length to 32"
                    set-netipaddress $slbmip2 -prefixlength 32
                }
                write-verbose "Finished configuring SLB Manager"
            } 
            TestScript = {
                #no need to test, just always set it to the correct value
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script CreatePublicIPAddress
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $ipAddress = New-NCPublicIPAddress -ResourceID $using:node.PublicIPResourceId -PublicIPAddress $using:node.GatewayPublicIPAddress
            } 
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $obj = Get-NCPublicIPAddress -ResourceId $using:node.PublicIPResourceId
                return ($obj -ne $null)
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script ConfigureMACAddressPool
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $macpool = New-NCMacPool -ResourceId $using:node.MACAddressPoolResourceId -StartMACAddress $using:node.MACAddressPoolStart -EndMACAddress $using:node.MACAddressPoolEnd
            } 
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $obj = Get-NCMacPool -ResourceId $using:node.MACAddressPoolResourceId
                return $obj -ne $null
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script ConfigureGatewayPools
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                # Get the Gre VIP Subnet Resource Ref
                foreach ($ln in $node.LogicalNetworks)
                {
                    if ($ln.Name -eq "GreVIP")
                    {
                        $greVipLogicalNetworkResourceId = $ln.ResourceId
                    }
                }

                $greVipNetworkObj = Get-NCLogicalNetwork -ResourceID $greVipLogicalNetworkResourceId
                $greVipSubnetResourceRef = $greVipNetworkObj.properties.subnets[0].resourceRef

                foreach ($gatewayPool in $node.GatewayPools) {
                    $gwPool = New-NCGatewayPool -ResourceId $gatewayPool.ResourceId -Type $gatewayPool.Type -GreVipSubnetResourceRef $greVipSubnetResourceRef `
                                                -PublicIPAddressId $using:node.PublicIPResourceId -Capacity $gatewayPool.Capacity -RedundantGatewayCount $gatewayPool.RedundantGatewayCount
                }                
            }
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                # retrieve the GW Pools to check if exist
                foreach ($gwPool in $using:node.GatewayPools)
                {
                    $obj = Get-NCGatewayPool -ResourceId $gwPool.ResourceId
                    if ($obj -eq $null)
                    { return $false }
                }
                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Configuration ConfigureSLBMUX
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Node $AllNodes.Where{$_.Role -eq "SLBMUX"}.NodeName
    {
        script DisableIPv6
        {
            setscript = {
                reg add hklm\system\currentcontrolset\services\tcpip6\parameters /v DisabledComponents /t REG_DWORD /d 255 /f
            }
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        script SetEncapOverheadPropertyOnNic
        {
            setscript = {
                Write-Verbose "Setting EncapOverhead property of the NIC on the SLB MUX machine"
                # The assumption here is that there is only one NIC on eatch SLB machine
                $nics = Get-NetAdapter -ErrorAction Ignore
                if(($nics -eq $null) -or ($nics.count -eq 0))
                {
                    throw "Failed to get available network adapters on the SLB machine"
                }
                
                $nic = $nics[0]
                $propValue = 160

                $nicProperty = Get-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -RegistryKeyword *EncapOverhead -ErrorAction Ignore
                if($nicProperty -eq $null)
                {
                    Write-Verbose "The *EncapOverhead property has not been added to the NIC $($nic.Name) yet. Adding the property and setting it to $($propValue)"
                    New-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword *EncapOverhead -RegistryValue $propValue
                    Write-Verbose "Added the *EncapOverhead property to the NIC $($nic.Name)."
                }
                else
                {
                    Write-Verbose "The *EncapOverhead property has been added to the NIC $($nic.Name) but the value is not the expected $($propValue), so setting it to $($propValue)."
                    Set-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -RegistryKeyword *EncapOverhead -RegistryValue $propValue
                    Write-Verbose "Changed the *EncapOverhead property value to $($propValue)."
                }
            }
            TestScript = {
                Write-Verbose "Checking EncapOverhead property of the NIC on the SLB MUX machine"
                $nics = Get-NetAdapter -ErrorAction Ignore
                if(($nics -eq $null) -or ($nics.count -eq 0))
                {
                    Write-verbose "Failed to get available network adapters on the SLB machine"
                    return $false
                }

                # The assumption here is that there is only one NIC on each SLB machine
                $nic = $nics[0]
                $nicProperty = Get-NetAdapterAdvancedProperty -Name $nic.Name -AllProperties -RegistryKeyword *EncapOverhead -ErrorAction Ignore
                if($nicProperty -eq $null)
                {
                    Write-Verbose "The *EncapOverhead property has not been added to the NIC $($nic.Name)"
                    return $false
                }

                if(($nicProperty.RegistryValue -eq $null) -or ($nicProperty.RegistryValue[0] -ne "160"))
                {
                    Write-Verbose "The value for the *EncapOverhead property on the NIC is not set to 160"
                    return $false
                }

                return $true
                
            }
            GetScript = {
                return @{ result = $true }
            }
        }   
        Script StartMUXTracing
        {
            SetScript = {
                cmd /c "netsh trace start globallevel=5 provider={6c2350f8-f827-4b74-ad0c-714a92e22576} report=di tracefile=c:\muxtrace.etl"                
            } 
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script DoAllCerts
        {                                      
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"
                
                $nccertname = "$($using:node.NetworkControllerRestName)"
                $ControllerCertificate="$($using:node.installsrcdir)\$($using:node.certfolder)\$($nccertname).pfx"
                $cn = (GetSubjectName($true)).ToUpper()
                
                write-verbose "Creating self signed certificate...";
                $existingCertList = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                foreach($existingCert in $existingCertList)
                {
                    del "Cert:\localmachine\my\$($existingCert.Thumbprint)"
                }
                
                GenerateSelfSignedCertificate $cn;

                $cert = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}

                Write-Verbose "Giving permission to network service for the mux certificate";
                GivePermissionToNetworkService $cert

                Write-Verbose "Adding Network Controller Certificates to trusted Root Store"
                AddCertToLocalMachineStore $ControllerCertificate "Root" "secret"

                Write-Verbose "Updating registry values for Mux"
                $muxService = "slbmux"

                try {
                   if ( (Get-Service $muxService).Status -eq "Running") {
                      Write-Verbose "Stopping $muxService"
                      Stop-Service -Name $muxService -ErrorAction Stop
                   } 
                } catch {
                   Write-Verbose "Error Stopping $muxService : $Error[0].ToString()"
                }

                Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name SlbmThumb -ErrorAction Ignore
                New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name SlbmThumb -PropertyType String -Value $nccertname

                Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name MuxCert -ErrorAction Ignore
                New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SlbMux" -Name MuxCert -PropertyType String -Value $cn

                Write-Verbose "Setting slbmux service to autostart"
                Set-Service $muxService -StartupType Automatic

                Write-Verbose "Starting slbmux service"
                Start-Service -Name $muxService

                Get-ChildItem -Path WSMan:\localhost\Listener | Where {$_.Keys.Contains("Transport=HTTPS") } | Remove-Item -Recurse -Force
                New-Item -Path WSMan:\localhost\Listener -Address * -HostName $cn -Transport HTTPS -CertificateThumbPrint $cert.Thumbprint -Force

                Write-Verbose "Enabling firewall rule for software load balancer mux"
                Get-Netfirewallrule -Group "@%SystemRoot%\system32\firewallapi.dll,-36902" | Enable-NetFirewallRule
            }
            TestScript = {
                write-verbose ("Checking network controller cert configuration.")
                $cert = get-childitem "Cert:\localmachine\my" -ErrorAction Ignore 
                if ($cert -eq $null) {
                    write-verbose ("cert:\localmachine\my cert not found.")
                    return $false
                }
                $nccertname = "$($using:node.NetworkControllerRestName)".ToUpper()
                
                $cert = get-childitem "Cert:\localmachine\root\" -ErrorAction Ignore | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}
                if ($cert -eq $null) {
                    write-verbose ("cert:\localmachine\root rest cert not found.")
                    return $false
                }
                
                if ((get-Service "slbmux").Status -ne "Running") {
                    return $false
                }

                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script AddVirtualServerToNC
        {
            SetScript = {
                Write-Verbose "Set AddVirtualServerToNC";
                
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"
                
                $hostname = (get-childitem -Path "HKLM:\software\microsoft\virtual machine\guest" | get-itemproperty).physicalhostname

                $MUXFQDN = "$($using:node.nodename).$($using:node.fqdn)"

                $nccred = get-nccredential -ResourceId $using:node.NCCredentialResourceId
                
                $connections = @()
                $connections += New-NCServerConnection -ComputerNames @($MUXFQDN) -Credential $nccred

                $cert = Get-ChildItem -Path Cert:\LocalMachine\My | where {$_.Subject -eq "CN=$MUXFQDN"}
                $certPath = "C:\$MUXFQDN.cer"

                Write-Verbose "Exporting certificate to the file system and converting to Base64 string...";
                Export-Certificate -Type CERT -FilePath $certPath -Cert $cert
                $file = Get-Content $certPath -Encoding Byte
                $base64 = [System.Convert]::ToBase64String($file)
                Remove-Item -Path $certPath
                
                $vmguid = (get-childitem -Path "HKLM:\software\microsoft\virtual machine\guest" | get-itemproperty).virtualmachineid
                $vsrv = new-ncvirtualserver -ResourceId $using:node.MuxVirtualServerResourceId -Connections $connections -Certificate $base64 -vmGuid $vmguid                
            } 
            TestScript = {
                Write-Verbose "Test AddVirtualServerToNC";
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                $obj = Get-NCVirtualServer -ResourceId $using:node.MuxVirtualServerResourceId
                return $obj -ne $null
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        Script AddMUXToNC
        {
            SetScript = {
                Write-Verbose "Set AddMUXToNC";
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword

                Write-Verbose "MuxVirtualServerResourceId $($using:node.MuxVirtualServerResourceId)";
                $vsrv = get-ncvirtualserver -ResourceId $using:node.MuxVirtualServerResourceId

                Write-Verbose "MuxPeerRouterName $($using:node.MuxPeerRouterName) MuxPeerRouterIP $($using:node.MuxPeerRouterIP) MuxPeerRouterASN $($using:node.MuxPeerRouterASN)";
                $peers = @()
                $peers += New-NCLoadBalancerMuxPeerRouterConfiguration -RouterName $using:node.MuxPeerRouterName -RouterIPAddress $using:node.MuxPeerRouterIP -peerASN $using:node.MuxPeerRouterASN
                $mux = New-ncloadbalancerMux -ResourceId $using:node.MuxResourceId -LocalASN $using:node.MuxASN -peerRouterConfigurations $peers -VirtualServer $vsrv
            } 
            TestScript = {
                Write-Verbose "Test AddMUXToNC";
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                Write-Verbose "MuxResourceId is $($using:node.MuxResourceId)";
                if ($using:node.MuxResourceId)
                {
                    $obj = Get-ncloadbalancerMux -ResourceId $using:node.MuxResourceId
                    return $obj -ne $null
                }
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }       
        Script StopMUXTracing
        {
            SetScript = {
                cmd /c "netsh trace stop"
            } 
            TestScript = {
                return $false
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Configuration AddGatewayNetworkAdapters
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    
    Node $AllNodes.Where{$_.Role -eq "HyperVHost"}.NodeName
    {
        $GatewayVMList = ($node.VMs | ? {$_.VMRole -eq "Gateway"})
                
        foreach ($VMInfo in $GatewayVMList) {
            Script "AddGatewayNetworkAdapter_$($VMInfo.VMName)"
            {
                SetScript = {                    
                    $vm = Get-VM -VMName $using:VMInfo.VMName -ErrorAction stop
                    Stop-VM $vm -ErrorAction stop

                    Add-VMNetworkAdapter -VMName $using:VMInfo.VMName -SwitchName $using:node.vSwitchName -Name "Internal" -StaticMacAddress $using:VMInfo.InternalNicMac
                    Add-VMNetworkAdapter -VMName $using:VMInfo.VMName -SwitchName $using:node.vSwitchName -Name "External" -StaticMacAddress $using:VMInfo.ExternalNicMac

                    Start-VM -VMName $using:VMInfo.VMName -ErrorAction stop
                }
                TestScript = {                        
                    $adapters = @(Get-VMNetworkAdapter –VMName $using:VMInfo.VMName)
                    if ($adapters.count -lt 3)
                    { return $false } 
                    else 
                    { return $true }
                }
                GetScript = {
                    return @{ result = @(Get-VMNetworkAdapter –VMName $using:VMInfo.VMName) }
                }
            }
        }
    }
}

Configuration ConfigureGatewayNetworkAdapterPortProfiles
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    
    Node $AllNodes.Where{$_.Role -eq "HyperVHost"}.NodeName
    {
        $GatewayVMList = ($node.VMs | ? {$_.VMRole -eq "Gateway"})
        
        foreach ($VMInfo in $GatewayVMList) {
            Script "SetPort_$($VMInfo.VMName)"
            {
                SetScript = {
                    . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1"
                    
                    write-verbose ("VM - $($using:VMInfo.VMName), Adapter - Internal")
                    set-portprofileid -ResourceID $using:VMInfo.InternalNicPortProfileId -vmname $using:VMInfo.VMName -VMNetworkAdapterName "Internal" -computername localhost -ProfileData "1" -Force
                    write-verbose ("VM - $($using:VMInfo.VMName), Adapter - External")
                    set-portprofileid -ResourceID $using:VMInfo.ExternalNicPortProfileId -vmname $using:VMInfo.VMName -VMNetworkAdapterName "External" -computername localhost -ProfileData "1" -Force
                }
                TestScript = {
                    $PortProfileFeatureId = "9940cd46-8b06-43bb-b9d5-93d50381fd56"

                    $adapters = Get-VMNetworkAdapter –VMName $using:VMInfo.VMName
                    $IntNic = $adapters | ? {$_.Name -eq "Internal"}
                    $ExtNic = $adapters | ? {$_.Name -eq "External"}
                    
                    $IntNicProfile = Get-VMSwitchExtensionPortFeature -FeatureId $PortProfileFeatureId -VMNetworkAdapter $IntNic
                    $ExtNicProfile = Get-VMSwitchExtensionPortFeature -FeatureId $PortProfileFeatureId -VMNetworkAdapter $ExtNic

                    return ($IntNicProfile.SettingData.ProfileData -eq "1" -and $IntNicProfile.SettingData.ProfileId -eq $using:VMInfo.InternalNicPortProfileId -and
                            $ExtNicProfile.SettingData.ProfileData -eq "1" -and $ExtNicProfile.SettingData.ProfileId -eq $using:VMInfo.ExternalNicPortProfileId)

                }
                GetScript = {
                    return @{ result = @(Get-VMNetworkAdapter –VMName $using:VMInfo.VMName) }
                }
            }
        }
    }
}

Configuration ConfigureGateway
{  
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node $AllNodes.Where{$_.Role -eq "Gateway"}.NodeName
    {
        WindowsFeature RemoteAccess
        {
            Ensure = "Present"
            Name = "RemoteAccess"
            IncludeAllSubFeature = $true
        }

        Script ConfigureRemoteAccess
        {
            SetScript = {              
                Add-WindowsFeature -Name RemoteAccess -IncludeAllSubFeature -IncludeManagementTools
                try { $RemoteAccess = Get-RemoteAccess } catch{$RemoteAccess = $null}
                    
                $hostname = (get-childitem -Path "HKLM:\software\microsoft\virtual machine\guest" | get-itemproperty).physicalhostname

                if($RemoteAccess -eq $null -or $RemoteAccess.VpnMultiTenancyStatus -ne "Installed")
                {
                    Write-Verbose "Installing RemoteAccess Multitenancy on $hostname"
                    Install-RemoteAccess -MultiTenancy
                }
            }
            TestScript = {
                try { $RemoteAccess = Get-RemoteAccess } catch{$RemoteAccess = $null}
                if($RemoteAccess -eq $null -or $RemoteAccess.VpnMultiTenancyStatus -ne "Installed")
                { return $false } 
                else 
                { return $true }
            }
            GetScript = {
                return @{ result = $RemoteAccess.VpnMultiTenancyStatus }
            }
        }

        Script InstallCerts
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\CertHelpers.ps1"

                $ControllerCertificateFolder="$($using:node.installsrcdir)\$($using:node.certfolder)\$($using:node.NetworkControllerRestName)"
                $certName = (GetSubjectName($true)).ToUpper()

                write-verbose "Creating self signed certificate if not exists...";
                GenerateSelfSignedCertificate $certName;

                $cn = "$($certName)".ToUpper()
                $cert = get-childitem "Cert:\localmachine\my" | where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")}

                $muxCertSubjectFqdn = GetSubjectFqdnFromCertificate $cert 
  
                Write-Verbose "Giving permission to network service for the certificate";
                GivePermissionToNetworkService $cert

                Write-Verbose "Adding Network Controller Certificates to trusted Root Store"
                AddCertToLocalMachineStore $ControllerCertificateFolder "Root" 

                Write-Verbose "Extracting Subject Name from Certificate "
                $controllerCertSubjectFqdn = GetSubjectFqdnFromCertificatePath $ControllerCertificateFolder

                Get-ChildItem -Path WSMan:\localhost\Listener | Where {$_.Keys.Contains("Transport=HTTPS") } | Remove-Item -Recurse -Force
                New-Item -Path WSMan:\localhost\Listener -Address * -HostName $certName -Transport HTTPS -CertificateThumbPrint $cert.Thumbprint -Force

                Write-Verbose "Enabling firewall rule"
                Get-Netfirewallrule -Group "@%SystemRoot%\system32\firewallapi.dll,-36902" | Enable-NetFirewallRule
            }
            TestScript = {
                write-verbose ("Checking network controller cert configuration.")
                $cert = get-childitem "Cert:\localmachine\my" -ErrorAction Ignore 
                if ($cert -eq $null) {
                    write-verbose ("cert:\localmachine\my cert not found.")
                    return $false
                }
                
                return $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
        
        Script AddVirtualServerToNC
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                              
                $hostname = (get-childitem -Path "HKLM:\software\microsoft\virtual machine\guest" | get-itemproperty).physicalhostname

                $GatewayFQDN = "$($using:node.nodename).$($using:node.fqdn)"

                $hostcred = get-nccredential -ResourceId $using:node.HostCredentialResourceId

                $connections = @()
                $connections += New-NCServerConnection -ComputerNames @($GatewayFQDN) -Credential $hostcred

                $vmguid = (get-childitem -Path "HKLM:\software\microsoft\virtual machine\guest" | get-itemproperty).virtualmachineid                
                $vsrv = new-ncvirtualserver -ResourceId $using:node.NodeName -Connections $connections -vmGuid $vmguid

            } 
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword

                $obj = Get-NCVirtualServer -ResourceId $using:node.NodeName
                return $obj -ne $null  #TODO: validate it has correct values before returning $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }

        Script AddGatewayToNC
        {
            SetScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword
                
                # Get Transit Subnet ResourceId
                foreach ($ln in $node.LogicalNetworks)
                {
                    if ($ln.Name -eq "Transit")
                    {
                        $transitLogicalNetworkResourceId = $ln.ResourceId
                    }
                }
                
                $transitNetwork = Get-NCLogicalNetwork -ResourceID $transitLogicalNetworkResourceId

                # Add new Interfaces for the GW VM                
                $InternalInterface = New-NCNetworkInterface -ResourceId $using:node.InternalNicPortProfileId -MacAddress $using:node.InternalNicMac
                $ExternalInterface = New-NCNetworkInterface -ResourceId $using:node.ExternalNicPortProfileId -MacAddress $using:node.ExternalNicMac -IPAddress $using:node.ExternalIPAddress -Subnet $transitNetwork.properties.Subnets[0]

                # Get the Gateway Pool reference
                $GatewayPoolObj = Get-NCGatewayPool -ResourceId $using:Node.GatewayPoolResourceId

                # Get the virtual Server reference
                $VirtualServerObj = Get-NCVirtualServer -ResourceId $using:node.NodeName 
        
                $GreBgpConfig = 
                @{
                    extAsNumber = "0.$($using:node.GreBgpRouterASN)"
                    bgpPeer = 
                    @(
                        @{
                            peerIP = $using:node.GreBgpPeerRouterIP
                            peerExtAsNumber = "0.$($using:node.GreBgpPeerRouterASN)"
                        }
                    )
                }

                # PUT new Gateway
                switch ($gatewayPoolObj.properties.type)
                {
                    { @("All", "S2sGre") -contains $_ }   {     
                                    $gateway = New-NCGateway -ResourceID $using:node.NodeName -GatewayPoolRef $GatewayPoolObj.resourceRef -Type $GatewayPoolObj.properties.type -BgpConfig $GreBgpConfig `
                                                            -VirtualServerRef $VirtualServerObj.resourceRef -ExternalInterfaceRef $ExternalInterface.resourceRef -InternalInterfaceRef $InternalInterface.resourceRef
                                }

                    "Forwarding"   { 
                                    $gateway = New-NCGateway -ResourceID $using:node.NodeName -GatewayPoolRef $GatewayPoolObj.resourceRef -Type $GatewayPoolObj.properties.type `
                                                            -VirtualServerRef $VirtualServerObj.resourceRef -ExternalInterfaceRef $ExternalInterface.resourceRef -InternalInterfaceRef $InternalInterface.resourceRef 
                                }
                }
                
            }
            TestScript = {
                . "$($using:node.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:node.NetworkControllerRestName -UserName $using:node.NCClusterUserName -Password $using:node.NCClusterPassword

                $obj = Get-NCGateway -ResourceId $using:node.NodeName
                return $obj -ne $null  #TODO: validate it has correct values before returning $true
            }
            GetScript = {
                return @{ result = $true }
            }
        }
    }
}

Workflow ConfigureHostNetworkingPreNCSetupWorkflow
{
     param(
      [Object]$ConfigData
     )

    Write-Verbose "ConfigureHostNetworkingPreNCSetupWorkflow Start"

    $nodeList = $ConfigData.AllNodes.Where{$_.Role -eq "HyperVHost"}

    Write-Verbose "Found $($nodeList.Count) Nodes"

    ForEach -Parallel -ThrottleLimit 10 ($hostNode in $nodeList) {

        # Variables used in several Inline Scripts
        $hostFQDN = "$($hostNode.NodeName).$($hostNode.fqdn)".ToLower()

        Write-Verbose "$($hostFQDN)"

        # Credential is used to run InlineScripts on Remote Hosts
        $psPwd = ConvertTo-SecureString $hostNode.HostPassword -AsPlainText -Force;
        $psCred = New-Object System.Management.Automation.PSCredential $hostNode.HostUserName, $psPwd;

        InlineScript {
            # DisableWfp
            Write-Verbose "DisableWfp";
        
            $hostNode = $using:hostNode.NodeName
            $switch = $using:hostNode.vSwitchName
            Disable-VmSwitchExtension -VMSwitchName $switch -Name "Microsoft Windows Filtering Platform"
        
            #Test DisableWfp
            Write-Verbose "Test Wfp disabled";
            if((get-vmswitchextension -VMSwitchName $switch -Name "Microsoft Windows Filtering Platform").Enabled -eq $true)
            {
                Write-Error "DisableWfp Failed on $($hostNode)"
            }
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end DisableWfp

        #Start host agent before enabling VFP to ensure that VFP unblocks the necessary ports as quickly as possible
        
        $NCIP = $hostNode.networkControllerRestIP
        $HostIP = [System.Net.Dns]::GetHostByName("$($hostNode.nodename).$($hostNode.fqdn)".ToLower()).AddressList[0].ToString()
        
        InlineScript {
            # SetNCConnection
            Write-Verbose "SetNCConnection";

            $connections = "ssl:$($using:NCIP):6640","pssl:6640:$($using:HostIP)"
            Write-Verbose "Connections Value $($connections)";
            Remove-ItemProperty -Path  "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name Connections -ErrorAction Ignore
            New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name Connections -PropertyType MultiString -Value @($connections)
            
            $peerCertCName = "$($using:hostNode.NetworkControllerRestName)".ToUpper()
            Write-Verbose "PeerCertificateCName Value $($peerCertCName)";
            Remove-ItemProperty -Path  "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name PeerCertificateCName -ErrorAction Ignore
            New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name PeerCertificateCName -PropertyType String -Value $peerCertCName
            
            $hostAgentCertCName = "$($using:hostNode.nodename).$($using:hostNode.fqdn)".ToUpper()
            Write-Verbose "HostAgentCertCName Value $($hostAgentCertCName)";
            Remove-ItemProperty -Path  "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name HostAgentCertificateCName -ErrorAction Ignore
            New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name HostAgentCertificateCName -PropertyType String -Value $hostAgentCertCName
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end SetNCConnection

        InlineScript {
            # Firewall Rules
            Write-Verbose "Firewall Rules";

            $fwrule = Get-NetFirewallRule -Name "Firewall-REST" -ErrorAction SilentlyContinue
            if ($fwrule -eq $null) {
                Write-Verbose "Create Firewall rule for NCHostAgent Rest";
                New-NetFirewallRule -Name "Firewall-REST" -DisplayName "Network Controller Host Agent REST" -Group "NcHostAgent" -Action Allow -Protocol TCP -LocalPort 80 -Direction Inbound -Enabled True
            }
            #Test Firewall-REST
            if((get-netfirewallrule -Name "Firewall-REST" -ErrorAction SilentlyContinue) -eq $null)
            {
                Write-Error "Create Firewall-REST Rule Failed on $($using:hostNode.NodeName)"
            }
        
            $fwrule = Get-NetFirewallRule -Name "Firewall-OVSDB" -ErrorAction SilentlyContinue
            if ($fwrule -eq $null) {
                Write-Verbose "Create Firewall rule for NCHostAgent OVSDB";
                New-NetFirewallRule -Name "Firewall-OVSDB" -DisplayName "Network Controller Host Agent OVSDB" -Group "NcHostAgent" -Action Allow -Protocol TCP -LocalPort 6640 -Direction Inbound -Enabled True
            }
            #Test Firewall-OVSDB
            if((get-netfirewallrule -Name "Firewall-OVSDB" -ErrorAction SilentlyContinue) -eq $null)
            {
                Write-Error "Create Firewall-OVSDB Rule Failed on $($using:hostNode.NodeName)"
            }
            
            $fwrule = Get-NetFirewallRule -Name "Firewall-HostAgent-TCP-IN" -ErrorAction SilentlyContinue
            if ($fwrule -eq $null) {
                Write-Verbose "Create Firewall rule for Firewall-HostAgent-TCP-IN";
                New-NetFirewallRule -Name "Firewall-HostAgent-TCP-IN" -DisplayName "Network Controller Host Agent (TCP-In)" -Group "Network Controller Host Agent Firewall Group" -Action Allow -Protocol TCP -LocalPort Any -Direction Inbound -Enabled True
            }
            #Test Firewall-OVSDB
            if((get-netfirewallrule -Name "Firewall-HostAgent-TCP-IN" -ErrorAction SilentlyContinue) -eq $null)
            {
                Write-Error "Create Firewall-HostAgent-TCP-IN Rule Failed on $($using:hostNode.NodeName)"
            }
            
            $fwrule = Get-NetFirewallRule -Name "Firewall-HostAgent-WCF-TCP-IN" -ErrorAction SilentlyContinue
            if ($fwrule -eq $null) {
                Write-Verbose "Create Firewall rule for Firewall-HostAgent-WCF-TCP-IN";
                New-NetFirewallRule -Name "Firewall-HostAgent-WCF-TCP-IN" -DisplayName "Network Controller Host Agent WCF(TCP-In)" -Group "Network Controller Host Agent Firewall Group" -Action Allow -Protocol TCP -LocalPort 80 -Direction Inbound -Enabled True
            }
            #Test Firewall-OVSDB
            if((get-netfirewallrule -Name "Firewall-HostAgent-WCF-TCP-IN" -ErrorAction SilentlyContinue) -eq $null)
            {
                Write-Error "Create Firewall-HostAgent-TCP-IN Rule Failed on $($using:hostNode.NodeName)"
            }
            
            $fwrule = Get-NetFirewallRule -Name "Firewall-HostAgent-TLS-TCP-IN" -ErrorAction SilentlyContinue
            if ($fwrule -eq $null) {
                Write-Verbose "Create Firewall rule for Firewall-HostAgent-TLS-TCP-IN";
                New-NetFirewallRule -Name "Firewall-HostAgent-TLS-TCP-IN" -DisplayName "Network Controller Host Agent WCF over TLS (TCP-In)" -Group "Network Controller Host Agent Firewall Group" -Action Allow -Protocol TCP -LocalPort 443 -Direction Inbound -Enabled True
            }
            #Test Firewall-OVSDB
            if((get-netfirewallrule -Name "Firewall-HostAgent-TLS-TCP-IN" -ErrorAction SilentlyContinue) -eq $null)
            {
                Write-Error "Create Firewall-HostAgent-TLS-TCP-IN Rule Failed on $($using:hostNode.NodeName)"
            }
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end Firewall Rules
        
        InlineScript {
            # Cleanup Old Certs
            Write-Verbose "Cleanup Old Certs using $($using:hostNode.InstallSrcDir)";

            # Host Cert in My
            $store = new-object System.Security.Cryptography.X509Certificates.X509Store("My", "LocalMachine")
            $store.open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $fqdn = "$($using:hostNode.fqdn)".ToUpper()
            $certs = $store.Certificates | Where {$_.Subject.ToUpper().Contains($fqdn)}
            foreach($cert in $certs) {
                $store.Remove($cert)
            }
            $store.Dispose()
            
            # NC Cert in Root
            $store = new-object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
            $store.open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $fqdn = "$($using:hostNode.fqdn)".ToUpper()
            $certs = $store.Certificates | Where {$_.Subject.ToUpper().Contains($fqdn)}
            foreach($cert in $certs) {
                $store.Remove($cert)
            }
            $store.Dispose()
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end Cleanup Old Certs

        InlineScript {
            # AddHostCert
            Set-ExecutionPolicy Bypass

            Write-Verbose "AddHostCert";
            . "$($using:hostNode.ToolsLocation)\CertHelpers.ps1"

            # Path to Certoc, only present in Nano
            $certocPath = "$($env:windir)\System32\certoc.exe"

            write-verbose "Querying self signed certificate ...";
            $cn = "$($using:hostFQDN)".ToUpper()
            $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")} | Select -First 1
            if ($cert -eq $null) {
                $certName = "$($using:hostNode.nodename).$($using:hostNode.FQDN)".ToUpper()
                $certPath = "c:\$($using:hostNode.certfolder)"
                $certPwd = $using:hostNode.HostPassword
                write-verbose "Adding Host Certificate to trusted My Store from [$certpath\$certName]"

                # Certoc only present in Nano, AddCertToLocalMachineStore only works on FullSKU
                if((test-path $certocPath) -ne $true) {
                    write-verbose "Adding $($certPath)\$($certName).pfx to My Store"
                    AddCertToLocalMachineStore "$($certPath)\$($certName).pfx" "My" "$($certPwd)"
                }
                else {
                    $fp = "certoc"
                    $arguments = "-importpfx -p $($certPwd) My $($certPath)\$($certName).pfx"
                    Write-Verbose "$($fp) arguments: $($arguments)";

                    $result = start-process -filepath $fp -argumentlist $arguments -wait -NoNewWindow -passthru
                    $resultString = $result.ExitCode
                    if($resultString -ne "0") {
                        Write-Error "certoc Result: $($resultString)"
                    }
                }

                $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where {$_.Subject.ToUpper().StartsWith("CN=$($cn)")} | Select -First 1
            }
        
            write-verbose "Giving permission to network service for the host certificate $($cert.Subject)"
            
            # Certoc only present in Nano, GivePermissionToNetworkService only works on FullSKU
            if((test-path $certocPath) -ne $true) {
                GivePermissionToNetworkService $cert
            }
            else {
                $output = certoc -store My $cert.Thumbprint
                $arr = $output.Trim(' ') -split '/n'
                $arr2 = $arr[11] -split ':'
                $uniqueKeyContainerName = ""
                if($arr2[0] -eq 'Unique name')
                {
                        
                    $uniqueKeyContainerName = $arr2[1].Trim(' ')
                    write-verbose "uniqueKeyContainerName $($uniqueKeyContainerName)"
                }
                else
                {
                    write-verbose "arr2 malformed: $($arr2)"
                }
                    
                $privKeyCertFile = Get-Item -path "$ENV:ProgramData\Microsoft\Crypto\RSA\MachineKeys\*"  | where {$_.Name -eq $uniqueKeyContainerName} | Select -First 1                
                write-verbose "Found privKeyCertFile $($privKeyCertFile)"
                $privKeyAcl = get-acl -Path $privKeyCertFile.FullName
                write-verbose "Got privKeyAcl $($privKeyAcl)"
                $permission = "NT AUTHORITY\NETWORK SERVICE","Read","Allow" 
                $accessRule = new-object System.Security.AccessControl.FileSystemAccessRule $permission 
                $privKeyAcl.AddAccessRule($accessRule)
                write-verbose "Added Access rule, setting ACL $($privKeyAcl) on file $($privKeyCertFile.FullName)"
                Set-Acl $privKeyCertFile.FullName $privKeyAcl
            }
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end AddHostCert

        InlineScript {
            # AddNCCert
            write-verbose "Adding Network Controller Certificates to trusted Root Store"
            . "$($using:hostNode.ToolsLocation)\CertHelpers.ps1"
            
            $certPath = "c:\$($using:hostNode.CertFolder)\$($using:hostNode.NetworkControllerRestName).pfx"
            $certPwd = "secret"
            
            #Certoc only present in Nano, AddCertToLocalMachineStore only works on FullSKU
            $certocPath = "$($env:windir)\System32\certoc.exe"
            if((test-path $certocPath) -ne $true) {
                write-verbose "Adding $($certPath) to Root Store with password $($certPwd)"
                AddCertToLocalMachineStore "$($certPath)" "Root" "$($certPwd)"
            }
            else {
                $fp = "certoc"
                $arguments = "-importpfx -p $($certPwd) Root $($certPath)"
                Write-Verbose "$($fp) arguments: $($arguments)";
                $result = start-process -filepath $fp -argumentlist $arguments -wait -NoNewWindow -passthru
                $resultString = $result.ExitCode
                if($resultString -ne "0") {
                    Write-Error "certoc Result: $($resultString)"
                }
            }
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end AddNCCert

        InlineScript {
            # NcHostAgent Restart
            Write-Verbose "NcHostAgent Restart";

            $service = Get-Service -Name NCHostAgent
            Stop-Service -InputObject $service -Force
            Set-Service -InputObject $service -StartupType Automatic
            Start-Service -InputObject $service
        } -psComputerName $hostNode.NodeName -psCredential $psCred 
        # end NcHostAgent Restart

        InlineScript {
            # EnableVFP
            Write-Verbose "EnableVFP";

            $hostNode = $using:hostNode.NodeName
            $switch = $using:hostNode.vSwitchName
            
            Enable-VmSwitchExtension -VMSwitchName $switch -Name "Windows Azure VFP Switch Extension"
            Write-Verbose "Wait 40 seconds for the VFP extention to be enabled"
            sleep 40
        
            #Test EnableVFP
            Write-Verbose "Test VFP enabled";
            if((get-vmswitchextension -VMSwitchName $switch -Name "Windows Azure VFP Switch Extension").Enabled -ne $true)
            {
                Write-Error "EnableVFP Failed on $($hostNode)"
            }
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end EnableVFP


    } # end ForEach -Parallel
}

Workflow ConfigureHostNetworkingPostNCSetupWorkflow
{
     param(
      [Object]$ConfigData
     )

    Write-Verbose "ConfigureHostNetworkingPostNCSetupWorkflow Start"

    $nodeList = $ConfigData.AllNodes.Where{$_.Role -eq "HyperVHost"}

    Write-Verbose "Found $($nodeList.Count) Nodes"

    ForEach -Parallel -ThrottleLimit 10 ($hostNode in $nodeList) {

        # Variables used in several Inline Scripts
        $hostFQDN = "$($hostNode.NodeName).$($hostNode.fqdn)".ToLower()

        Write-Verbose "$($hostFQDN)"

        # Credential is used to run InlineScripts on Remote Hosts
        $psPwd = ConvertTo-SecureString $hostNode.HostPassword -AsPlainText -Force;
        $psCred = New-Object System.Management.Automation.PSCredential $hostNode.HostUserName, $psPwd;
        
        $slbmVip = InlineScript {
            # GetSlbmVip
            Write-Verbose "GetSlbmVip";
            . "$($using:hostNode.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:hostNode.NetworkControllerRestName -UserName $using:hostNode.NCClusterUserName -Password $using:hostNode.NCClusterPassword
            
            $slb = (Get-NCLoadbalancerManager).properties.loadbalancermanageripaddress
            Write-Verbose "SlbmVip: $($slb)";
            return $slb
        } -psComputerName $env:Computername -psCredential $psCred
        # end GetSlbmVip

        InlineScript {
            # CreateSLBConfigFile
            Write-Verbose "CreateSLBConfigFile";

            $slbhpconfigtemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<SlbHostPluginConfiguration xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <SlbManager>
        <HomeSlbmVipEndpoints>
            <HomeSlbmVipEndpoint>{0}:8570</HomeSlbmVipEndpoint>
        </HomeSlbmVipEndpoints>
        <SlbmVipEndpoints>
            <SlbmVipEndpoint>{1}:8570</SlbmVipEndpoint>
        </SlbmVipEndpoints>
        <SlbManagerCertSubjectName>{2}</SlbManagerCertSubjectName>
    </SlbManager>
    <SlbHostPlugin>
        <SlbHostPluginCertSubjectName>{3}</SlbHostPluginCertSubjectName>
    </SlbHostPlugin>
    <NetworkConfig>
        <MtuSize>0</MtuSize>
        <JumboFrameSize>4088</JumboFrameSize>
        <VfpFlowStatesLimit>500000</VfpFlowStatesLimit>
    </NetworkConfig>
</SlbHostPluginConfiguration>
'@
                $ncfqdn = "$($using:hostNode.NetworkControllerRestName)".ToLower()
                
                $slbhpconfig = $slbhpconfigtemplate -f $using:slbmVip, $using:slbmVip, $ncfqdn, $using:hostFQDN
                write-verbose $slbhpconfig
                set-content -value $slbhpconfig -path 'c:\windows\system32\slbhpconfig.xml' -encoding UTF8
        } -psComputerName $hostNode.NodeName -psCredential $psCred
        # end CreateSLBConfigFile

        InlineScript {
            # SLBHostAgent Restart
            Write-Verbose "SLBHostAgent Restart";

            #this should be temporary fix
            $tracingpath = "C:\Windows\tracing"
            if((test-path $tracingpath) -ne $true) {
                mkdir $tracingpath
            }

            $service = Get-Service -Name SlbHostAgent
            Stop-Service -InputObject $service -Force
            Set-Service -InputObject $service -StartupType Automatic
            Start-Service -InputObject $service
        } -psComputerName $hostNode.NodeName -psCredential $psCred 
        # end SLBHostAgent Restart      
        
        $resourceId = InlineScript {
            # Get ResourceId
            Write-Verbose "Get ResourceId for server $($using:hostNode.NodeName)."

            return (Get-VMSwitch)[0].Id
        } -psComputerName $hostNode.NodeName -psCredential $psCred 

        $instanceId = InlineScript {
            # AddHostToNC
            Write-Verbose "AddHostToNC";
            . "$($using:hostNode.InstallSrcDir)\Scripts\NetworkControllerRESTWrappers.ps1" -ComputerName $using:hostNode.NetworkControllerRestName -UserName $using:hostNode.NCClusterUserName -Password $using:hostNode.NCClusterPassword
            
            Write-Verbose "ResourceId (VMswitch[0]): $($using:resourceId).";
            $hostcred = get-nccredential -ResourceId $using:hostNode.HostCredentialResourceId
            Write-Verbose "NC Host Credential: $($hostcred)";
            $nccred = get-nccredential -ResourceId $using:hostNode.NCCredentialResourceId
            Write-Verbose "NC NC Credential: $($nccred)";
            
            $ipaddress = [System.Net.Dns]::GetHostByName($using:hostFQDN).AddressList[0].ToString()
        
            $connections = @()
            $connections += New-NCServerConnection -ComputerNames @($ipaddress, $using:hostFQDN) -Credential $hostcred -Verbose
            $connections += New-NCServerConnection -ComputerNames @($ipaddress, $using:hostFQDN) -Credential $nccred -Verbose
        
            $ln = get-nclogicalnetwork -ResourceId $using:hostNode.PALogicalNetworkResourceId -Verbose
            
            $pNICs = @()
            $pNICs += New-NCServerNetworkInterface -LogicalNetworksubnets ($ln.properties.subnets) -Verbose

            $certPath = "$($using:hostNode.InstallSrcDir)\$($using:hostNode.CertFolder)\$($using:hostFQDN).cer"
            write-verbose "Getting cert file content: $($certPath)"
            $file = Get-Content $certPath -Encoding Byte
            write-verbose "Doing conversion to base64"
            $base64 = [System.Convert]::ToBase64String($file)
            
            $server = New-NCServer -ResourceId $using:resourceId -Connections $connections -PhysicalNetworkInterfaces $pNICs -Certificate $base64 -Verbose
            
            #Test AddHostToNC
            $obj = Get-NCServer -ResourceId $using:resourceId
            if($obj -eq $false)
            {
                Write-Error "Adding Host to NC Failed on $($using:hostNode.NodeName)"
                return $null
            }

            return $obj.instanceId
        } -psComputerName $env:Computername -psCredential $psCred

        InlineScript {
            Write-Verbose "Setting Host Id $($using:instanceId)."

            Remove-ItemProperty -Path  "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name HostId -ErrorAction Ignore
            New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NcHostAgent\Parameters" -Name HostId -PropertyType String -Value @($using:instanceId)

            Write-Verbose "Restarting NcHostAgent.";
            Restart-Service NCHostAgent -Force
            
            Write-Verbose "Restarting SlbHostAgent.";
            Restart-Service SlbHostAgent -Force
        } -psComputerName $hostNode.NodeName -psCredential $psCred 
        # end AddHostToNC

    } # end ForEach -Parallel
}

Configuration CleanUp
{  
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node $AllNodes.NodeName
    {
        script "RemoveCertsDirectory"
        {
            SetScript = {
                write-verbose "Removing contents of Certs directory"
                rm -recurse -force "$($env:systemdrive)\$($Using:node.CertFolder)\*"
            }
            TestScript = {
                return ((Test-Path "$($env:systemdrive)\$($Using:node.CertFolder)") -ne $True)
            }
            GetScript = {
                return @{ result = $true }
            }
        }    
    }
}

function GetOrCreate-PSSession
{
    param ([Parameter(mandatory=$false)][string]$ComputerName,
           [PSCredential]$Credential = $null )

    # Get or create PS Session to the HyperVHost
    $PSSessions = @(Get-PSSession | ? {$_.ComputerName -eq $ComputerName})

    foreach($session in $PSSessions)
    {
        if ($session.State -ne "Opened" -and $session.Availability -ne "Available")
        { $session | remove-pssession -Confirm:$false -ErrorAction ignore }
        else
        { return $session }        
    }

    # No valid PSSession found, create a new one
    if ($Credential -eq $null)
    { return (New-PSSession -ComputerName $ComputerName -ErrorAction Ignore) }
    else
    { return (New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Ignore) }
}

function RenameGatewayNetworkAdapters
{
    param([Object] $ConfigData)

    $GatewayNodes = @($configdata.AllNodes | ? {$_.Role -eq "Gateway"})

    foreach ($node in $GatewayNodes) {
        klist purge | out-null  #clear kerberos ticket cache 
    
        write-verbose "Attempting to contact $($node.NodeName)."
        $ps = GetOrCreate-PSSession -computername $node.NodeName 
        if ($ps -eq $null) { return }

        $result = Invoke-Command -Session $ps -ScriptBlock {
                param($InternalNicMac, $ExternalNicMac)
                 
                $Adapters = @(Get-NetAdapter)
                $InternalAdapter = $Adapters | ? {$_.MacAddress -eq $InternalNicMac}
                $ExternalAdapter = $Adapters | ? {$_.MacAddress -eq $ExternalNicMac}

                if ($InternalAdapter -ne $null)
                { Rename-NetAdapter -Name $InternalAdapter.Name -NewName "Internal" -Confirm:$false }
                if ($ExternalAdapter -ne $null)
                { Rename-NetAdapter -Name $ExternalAdapter.Name -NewName "External" -Confirm:$false }
            } -ArgumentList @($node.InternalNicMac, $node.ExternalNicMac)        
    }
}

function WaitForComputerToBeReady
{
    param(
        [string[]] $ComputerName,
        [Switch]$CheckPendingReboot
    )


    foreach ($computer in $computername) {        
        write-verbose "Waiting for $Computer to become active."
        
        $continue = $true
        while ($continue) {
            try {
                $ps = $null
                $result = ""
                
                klist purge | out-null  #clear kerberos ticket cache 
                Clear-DnsClientCache    #clear DNS cache in case IP address is stale
                
                write-verbose "Attempting to contact $Computer."
                $ps = GetOrCreate-pssession -computername $Computer -erroraction ignore
                if ($ps -ne $null) {
                    if ($CheckPendingReboot) {                        
                        $result = Invoke-Command -Session $ps -ScriptBlock { 
                            if (Test-Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
                                "Reboot pending"
                            } 
                            else {
                                hostname 
                            }
                        }
                    }
                    else {
                        try {
                            $result = Invoke-Command -Session $ps -ScriptBlock { hostname }
                        } catch { }
                    }
                }
                if ($result -eq $Computer) {
                    $continue = $false
                    break
                }
                if ($result -eq "Reboot pending") {
                    write-verbose "Reboot pending on $Computer.  Waiting for restart."
                }
            }
            catch 
            {
            }
            write-verbose "$Computer is not active, sleeping for 10 seconds."
            sleep 10
        }
    write-verbose "$Computer IS ACTIVE.  Continuing with deployment."
    }
}

function GetRoleMembers
{
param(
    [Object] $ConfigData,
    [String[]] $RoleNames
)
    $results = @()

    foreach ($node in $configdata.AllNodes) {
        if ($node.Role -in $RoleNames) {
            $results += $node.NodeName
        }
    }
    if ($results.count -eq 0) {
        throw "No node with NetworkController role found in configuration data"
    }
    return $results
}

function RestartRoleMembers
{
param(
    [Object] $ConfigData,
    [String[]] $RoleNames,
    [Switch] $Wait,
    [Switch] $Force
)
    $results = @()

    foreach ($node in $configdata.AllNodes) {
        if ($node.Role -in $RoleNames) {
                write-verbose "Restarting $($node.NodeName)"
                $ps = GetOrCreate-pssession -ComputerName $($node.NodeName)
                Invoke-Command -Session $ps -ScriptBlock { 
                    if ($using:Force -or (Test-Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")) {
                        Restart-computer -Force -Confirm:$false
                    }
                }
        }
    }
    
    sleep 10

    if ($wait.IsPresent) {
        WaitForComputerToBeReady -ComputerName $(GetRoleMembers $ConfigData @("NetworkController")) -CheckPendingReboot
    }
}

function GatherCerts
{
param(
    [Object] $ConfigData
)
    $nccertname = $ConfigData.allnodes[0].NetworkControllerRestName

    write-verbose "Finding NC VM with REST cert."
    foreach ($n in $configdata.allnodes) {
        if (($n.role -eq "NetworkController") -and ($n.ServiceFabricRingMembers -ne $null)) {
            write-verbose "NC REST host is $($n.nodename)."
            $ncresthost = $n.nodename

            Write-Verbose "Copying all certs to the installation sources cert directory."
            $NCCertSource = "\\$($ncresthost)\c$\$($nccertname)"
            $NCCertDestination = "$($configData.AllNodes[0].installsrcdir)\$($configData.AllNodes[0].certfolder)"

            write-verbose ("Copying REST cert from [{0}] to [{1}]" -f $NCCertSource, $NCCertDestination)
            copy-item -path $NCCertSource -Destination $NCCertDestination

            if(Test-Path "$NCCertSource.pfx") {
                write-verbose ("Copying REST cert pfx from [{0}] to [{1}]" -f "$NCCertSource.pfx", $NCCertDestination)
                copy-item -path "$NCCertSource.pfx" -Destination $NCCertDestination
            }

            foreach ($n2 in $configdata.allnodes) {
                if ($n2.role -eq "NetworkController") {
                    $NCCertSource = '\\{0}\c$\{1}.{2}.pfx' -f $ncresthost, $n2.NodeName, $nccertname
                    $fulldest = "$($NCCertDestination)\$($n2.NodeName).$($nccertname).pfx"

                    write-verbose ("Copying NC Node cert pfx from [{0}] to [{1}]" -f $NCCertSource, $fulldest)
                    copy-item -path $NCCertSource -Destination $fulldest
                }
                elseif ($n2.role -eq "HyperVHost") {
                    $CertName = "$($n2.nodename).$($n2.FQDN)".ToUpper()
                    $HostCertSource = '\\{0}\c$\{1}' -f $ncresthost, $CertName
                    $fulldest = "$($NCCertDestination)\$($CertName)"

                    write-verbose ("Copying Host Node cert from [{0}] to [{1}]" -f "$HostCertSource.cer", "$fulldest.cer")
                    copy-item -path "$HostCertSource.cer" -Destination "$fulldest.cer"

                    write-verbose ("Copying Host Node cert pfx from [{0}] to [{1}]" -f "$HostCertSource.pfx", "$fulldest.pfx")
                    copy-item -path "$HostCertSource.pfx" -Destination "$fulldest.pfx"
                }
            }

            break
        }
    }
}

function CleanupMOFS
{  
    Remove-Item .\SetHyperVWinRMEnvelope -Force -Recurse 2>$null
    Remove-Item .\DeployVMs -Force -Recurse 2>$null
    Remove-Item .\ConfigureNetworkControllerVMs -Force -Recurse 2>$null
    Remove-Item .\CreateControllerCert -Force -Recurse 2>$null
    Remove-Item .\InstallControllerCerts -Force -Recurse 2>$null
    Remove-Item .\EnableNCTracing -Force -Recurse 2>$null
    Remove-Item .\DisableNCTracing -Force -Recurse 2>$null    
    Remove-Item .\ConfigureNetworkControllerCluster -Force -Recurse 2>$null
    Remove-Item .\ConfigureSLBMUX -Force -Recurse 2>$null
    Remove-Item .\AddGatewayNetworkAdapters -Force -Recurse 2>$null
    Remove-Item .\ConfigureGatewayNetworkAdapterPortProfiles -Force -Recurse 2>$null
    Remove-Item .\ConfigureGateway -Force -Recurse 2>$null
    Remove-Item .\CopyToolsAndCerts -Force -Recurse 2>$null
    Remove-Item .\CleanUp -Force -Recurse 2>$null
}

function CompileDSCResources
{
    SetHyperVWinRMEnvelope -ConfigurationData $ConfigData -verbose
    DeployVMs -ConfigurationData $ConfigData -verbose
    ConfigureNetworkControllerVMs -ConfigurationData $ConfigData -verbose
    CreateControllerCert -ConfigurationData $ConfigData -verbose
    InstallControllerCerts -ConfigurationData $ConfigData -verbose
    EnableNCTracing -ConfigurationData $ConfigData -verbose
    DisableNCTracing -ConfigurationData $Configdata -verbose
    ConfigureNetworkControllerCluster -ConfigurationData $ConfigData -verbose
    ConfigureSLBMUX -ConfigurationData $ConfigData -verbose 
    AddGatewayNetworkAdapters -ConfigurationData $ConfigData -verbose 
    ConfigureGatewayNetworkAdapterPortProfiles  -ConfigurationData $ConfigData -verbose 
    ConfigureGateway -ConfigurationData $ConfigData -verbose
    CopyToolsAndCerts -ConfigurationData $ConfigData -verbose
    CleanUp -ConfigurationData $ConfigData -verbose
}



if ($psCmdlet.ParameterSetName -ne "NoParameters") {

    $global:stopwatch = [Diagnostics.Stopwatch]::StartNew()

    switch ($psCmdlet.ParameterSetName) 
    {
        "ConfigurationFile" {
            Write-Verbose "Using configuration from file [$ConfigurationDataFile]"
            $configdata = [hashtable] (iex (gc $ConfigurationDataFile | out-string))
        }
        "ConfigurationData" {
            Write-Verbose "Using configuration passed in from parameter"
            $configdata = $configurationData 
        }
    }

    Set-ExecutionPolicy Bypass -Scope Process
    
    write-verbose "STAGE 1: Cleaning up previous MOFs"

    CleanupMOFS

    write-verbose "STAGE 2.1: Compile DSC resources"

    CompileDSCResources
    
    write-verbose "STAGE 2.2: Set WinRM envelope size on hosts"

    Start-DscConfiguration -Path .\SetHyperVWinRMEnvelope -Wait -Force -Verbose -Erroraction Stop

    write-verbose "STAGE 3: Deploy VMs"

    Start-DscConfiguration -Path .\DeployVMs -Wait -Force -Verbose -Erroraction Stop
    WaitForComputerToBeReady -ComputerName $(GetRoleMembers $ConfigData @("NetworkController", "SLBMUX", "Gateway"))

    write-verbose "STAGE 4: Install Network Controller nodes"

    Start-DscConfiguration -Path .\ConfigureNetworkControllerVMs -Wait -Force -Verbose -Erroraction Stop
    WaitForComputerToBeReady -ComputerName $(GetRoleMembers $ConfigData @("NetworkController")) -CheckPendingReboot 

    write-verbose "STAGE 5.1: Generate controller certificates"
    
    Start-DscConfiguration -Path .\CreateControllerCert -Wait -Force -Verbose -Erroraction Stop

    write-verbose "STAGE 5.2: Gather controller certificates"
    
    GatherCerts -ConfigData $ConfigData

    write-verbose "STAGE 6: Distribute Tools and Certs to all nodes"

    Start-DscConfiguration -Path .\CopyToolsAndCerts -Wait -Force -Verbose -Erroraction Stop

    write-verbose "STAGE 7: Install controller certificates"

    Start-DscConfiguration -Path .\InstallControllerCerts -Wait -Force -Verbose -Erroraction Stop

    write-verbose "STAGE 8: Configure Hyper-V host networking (Pre-NC)"

    ConfigureHostNetworkingPreNCSetupWorkflow -ConfigData $ConfigData -Verbose -Erroraction Stop
    
    try
    {
        write-verbose "STAGE 9: Configure NetworkController cluster"
        
        Start-DscConfiguration -Path .\EnableNCTracing -Wait -Force  -Verbose -Erroraction Ignore
        Start-DscConfiguration -Path .\ConfigureNetworkControllerCluster -Wait -Force -Verbose -Erroraction Stop

        write-verbose ("Importing NC Cert to trusted root store of deployment machine" )
        $scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
        . "$($scriptPath)\certhelpers.ps1"
        AddCertToLocalMachineStore "$($configData.AllNodes[0].installsrcdir)\$($configData.AllNodes[0].certfolder)\$($configData.AllNodes[0].NetworkControllerRestName)" "Root"
    
        write-verbose "STAGE 10: Configure Hyper-V host networking (Post-NC)"

        ConfigureHostNetworkingPostNCSetupWorkflow -ConfigData $ConfigData -Verbose -Erroraction Stop
    
        write-verbose "STAGE 11: Configure SLBMUXes"
        
        if ((Get-ChildItem .\ConfigureSLBMUX\).count -gt 0) {
            Start-DscConfiguration -Path .\ConfigureSLBMUX -wait -Force -Verbose -Erroraction Stop
        } else {
            write-verbose "No muxes defined in configuration."
        }

        write-verbose "STAGE 12.1: Configure Gateway Network Adapters"
    
        Start-DscConfiguration -Path .\AddGatewayNetworkAdapters -Wait -Force -Verbose -Erroraction Stop
        WaitForComputerToBeReady -ComputerName $(GetRoleMembers $ConfigData @("Gateway"))
        
        #TODO: add and rename nic as part of VM creation
        write-verbose "STAGE 12.2: Rename network adapters on Gateway VMs"
    
        RenameGatewayNetworkAdapters $ConfigData

        write-verbose "STAGE 12.3: Configure Gateways"
        if ((Get-ChildItem .\ConfigureGateway\).count -gt 0) {
            Start-DscConfiguration -Path .\ConfigureGateway -wait -Force -Verbose -Erroraction Stop
            Write-verbose "Sleeping for 30 sec before plumbing the port profiles for Gateways"
            Sleep 30
            Start-DscConfiguration -Path .\ConfigureGatewayNetworkAdapterPortProfiles -wait -Force -Verbose -Erroraction Stop
        } else {
            write-verbose "No gateways defined in configuration."
        }
    }
    catch {
        Write-Verbose "Exception: $_"
        throw
    }
    finally
    {
        Write-Verbose "Disabling tracing for NC."
        Start-DscConfiguration -Path .\DisableNCTracing -Wait -Force -Verbose -Erroraction Ignore
    }

    Write-Verbose "Cleaning up."
    Start-DscConfiguration -Path .\CleanUp -Wait -Force -Verbose -Erroraction Ignore

    CleanupMOFS
    
    $global:stopwatch.stop()
    write-verbose "TOTAL RUNNING TIME: $($global:stopwatch.Elapsed.ToString())"
}