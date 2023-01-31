#requires -runasadministrator

function Loading{   #Cosmetic function that outputs a pattern until it finishes deleting files in the background
    [cmdletbinding()]
    $Del = start-job -name DeleteISI -ScriptBlock {remove-item -path "\\cgrnyisi\homeshare\$user\settingspackages\*" -force -recurse -whatif -ErrorAction stop}
    $JobState = @('Completed', 'Failed')
    $dots = @('*')*20
    
    Write-Verbose "LOADING..."

    
    do{
        for([int]$i = 0; $i -lt 10; $i++){
            $dots[$i] = '|'
            $dots[-1 - $i] = '|'
            write-host "$dots" -ForegroundColor green
            start-sleep -milliseconds 150

            if($i -eq 9){
            
            
                for([int]$j = 9; $j -gt -1; $j--){
                    $dots[$j] = '*'
                    $dots[19 - $j] = '*'
                    write-host "$dots" -ForegroundColor green
                    start-sleep -milliseconds 150
                }
            }
        }
        start-sleep -milliseconds 150
    }until($del.state -in $JobState) 

    if($del.state -eq 'Failed'){
        write-warning "Deletion job failed."
        return 
    }

    Write-Verbose "\\cgrnyisi\homeshare\$user\settingspackages\ deletion state: $($del.state)"
}

function ValidateUser{            #Run on target machine to aggregate all C:\User\ paths and cross-check with supplied username to make sure they're present 

    if(get-childitem "HKLM:Software\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue | where {$_.GetValue('ProfileImagePath') -eq "C:\Users\$using:user"}){
        return $true
    }
    return $false
}

<############ MAIN ############>


    <#

.SYNOPSIS
    Remove-UserProfile deletes a user's profile from a machine, either implicitly or explicitly. 

.DESCRIPTION 
    Remove-UserProfile will delete a user's profile from a specified machine. You may include the targeted username via the User parameter or, if left unspecified, it will assume you are attempting to delete the profile
    of the currently logged-on user on said machine. If a User parameter is specified, the script will first validate the user to make sure there is, in fact, a profile associated with them on the machine (this check
    is not performed if User parameter is not included). If valid, the script will then restart the computer and, after it's back online, will then delete the folders located at: C:\Users\%username% , 
    HKLM:Software\Microsoft\Windows NT\CurrentVersion\ProfileList\%user's SID% , \\cgrnyisi\homeshare\%username%\settingspackages. Finally, the computer will restart again. 

.PARAMETER Computername
    The name of the computer that contains the user profile in question. No IP addresses.
.PARAMETER User 
    Standard network username for the user whose profile is being deleted.

.EXAMPLE 
    Remove-UserProfile -ComputerName IT-471ZFK2 -User rozdoa
    This will delete the specified user's profile on said machine. 
.EXAMPLE 
    Remove-UserProfile 0408-6blzv23 -verbose
    This will perform the same action, however since no user is specified the script will grab the currently logged-on user and delete their profile. 
    Also note the verbose flag, which will output additional information as the command runs. 

.NOTES
    [*] This script requires you run it under administrator privileges. 
    [*] Targeted computer must have PowerShell remoting capabilites enabled. 
    [*] This script cannot run on the local host. 
    [*] The computer name parameter is mandatory; the user parameter is not. If a user is not specified, it will assume the user in question is the one currently logged on.  
    [*] If you do not specify a user, there must be someone actively logged onto the computer (so the computer cannot be locked, asleep, or shutdown). Specifying the user will work if the computer is locked. 
    [*] The '-verbose' flag can be used to see extra information outputted during the function's run and is recommended to see the script's progress. 

    #>
function Remove-UserProfile{            

[cmdletbinding()]
param(
 [parameter(valuefrompipelinebypropertyname, mandatory, position = 0)][alias('host','cn')][validatepattern("\S{2,6}-.{3,7}")][string]$ComputerName,   
 [parameter(valuefrompipelinebypropertyname, position = 1)][validatepattern("^\D+$")][string]$User
)

BEGIN{
    write-verbose "Script started -- $(get-date)"
    $validuserbool = $false 
}

PROCESS{
   if($ComputerName -eq $env:computername){            #Script restarts at some point; cannot run on localhost
        write-warning "Script cannot run on local machine."
        exit 1
    } 


    if(!($psboundparameters.ContainsValue($user))){            #If user parameter not specified, run below to retrieve currently logged on user on target machine 
        
        try{
            $session = New-CimSession -ComputerName $computername -SessionOption (new-cimsessionoption -protocol Wsman) -ErrorAction stop
            $user = ((Get-CimInstance win32_computersystem -CimSession $session | select -expand username).split('\')[1])
            $validuserbool = $true            #Currently logged on user, by definition, must be a valid user on machine; skips check 
        }
        catch [Microsoft.Management.Infrastructure.CimException]{
            write-warning "Could not connect to $($ComputerName.toupper()) to extract currently logged on user. Please check the name provided is spelled correctly or that the machine is accepting remote connections."
            exit 1
        }
        catch{
            write-warning "An unknown error has occurred when attempting to connect to $($computername.toupper()) to extract its username."
            exit 1
        }
    }
    
    Write-Verbose "Attempting to validate $($user.toupper()) on $($computername.toupper())."

    try{
        
        if(!$validuserbool){

        $ValidUserBool = invoke-command -ComputerName $ComputerName -ScriptBlock ${function:ValidateUser} -ErrorAction Stop 

        }

        Write-Verbose "VALID: $validuserbool"
    }
    catch [System.Management.Automation.Remoting.PSRemotingTransportException]{
        write-warning "Could not connect to $($ComputerName.toupper()) because its name was invalid or because Powershell remoting is not enabled on the remote/local computer. Please verify and try again."
        exit 1
    }
    catch{
        write-warning "An unknown error has occurred when attempting to connect to $($computername.toupper())."
        exit 1
    }

    if($ValidUserBool){            #Execute only if user is valid 

        Write-Verbose "$($user.toupper()) is a valid user on $($computername.toupper())."

        try{
            $error.clear()            #Clear global error variable for error report in catch block below 

            Write-Verbose "Restart command sent." 
            restart-computer -ComputerName $computername -protocol WSMan -ErrorAction stop -Force -Confirm  -WhatIf            #Waits for computer to finish restart before proceeding; max wait 10 minutes before stopping 
            
            write-verbose "Waiting for network connectivity..."
            start-sleep -Seconds 2

           

            if(test-connection -ComputerName $computername -ErrorAction stop -quiet){            
                write-verbose "Ping to $($ComputerName.toupper()) successful."

                $DeleteScriptBlock = {            #Deletes HKLM key & user profile file on their machine; not necessary to include cgrnyisi here since can be done on our end 
 
                    get-childitem "HKLM:Software\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction stop | where {$_.GetValue('ProfileImagePath') -eq "C:\Users\$using:user"} | remove-item -force -recurse -whatif -ErrorAction Stop 
                    remove-item -path "C:\Users\$using:user\" -recurse -force -whatif -erroraction Stop 
                    

                    Restart-Computer -Force -WhatIf
                    
                }

                Write-Verbose "Attempting to delete HKLM key, C:\Users\$user, and \\cgrnyisi\homeshare\$user\settingspackages on $($computername.toupper()) for $($user.toupper())."

                loading -verbose            #Cosmetic function called; deletes cgrnyisi path with visual on console

                invoke-command -ComputerName $computername -ScriptBlock $DeleteScriptBlock -ErrorAction Stop 

                Write-Verbose "Deleted HKLM key & C:\Users\$user successfully; restarting $($ComputerName.toupper())."
            }
            else{
                write-warning "Network timeout; cannot establish remote session with $($ComputerName.toupper())"
                exit 1 
            }

        }
        catch [System.Net.NetworkInformation.PingException]{            
            write-warning "Could not ping $($ComputerName.ToUpper()) to restart. Verify connectivity."
            exit 1 
        }
        catch [System.InvalidOperationException]{
            write-warning "Could not restart $($ComputerName.toupper()). Please verify the name and try again."
            exit 1
        }
        catch [System.Management.Automation.Remoting.PSRemotingTransportException]{
            write-warning "Could not connect to $($ComputerName.toupper()) because its name was invalid or because Powershell remoting is not enabled on the remote/local computer. Please verify and try again."
            exit 1
        }
        catch [System.Management.Automation.ItemNotFoundException]{
            write-warning "$($error[0] | select -expand TargetObject) does not exist."
            exit 1
        }
        catch [System.Management.Automation.RemoteException]{
            write-warning "$($error[0] | select -expand exception)"
            exit 1
        }
        catch{
            write-warning "An unknown error has occurred."
            exit 1
        }

    }
    else{
        write-warning "$($user.toupper()) does not have a profile on the selected machine."
        exit 1

    }



}#PROCESS

END{
    Write-Verbose "Script completed -- $(get-date)"
}

}#FUNC