# Golden image pipeline configuration. No secrets here: credentials are SecretManagement names.
@{
  # Folders for run state, HTML reports and logs (relative = under the Pipeline folder)
  Paths      = @{ State = 'state'; Reports = 'reports'; Logs = 'logs' }

  # vCenter used for snapshots, power operations and guest operations
  vCenter    = @{ Server = 'vcsa01.domain.local'; CredentialSecret = 'GI-vCenter' }

  # Horizon Connection Server REST API
  Horizon    = @{ Server = 'hzcs01.domain.local'; CredentialSecret = 'GI-Horizon'; Domain = 'DOMAIN'; SkipCertificateCheck = $false }

  # App Volumes Manager REST API
  AppVolumes = @{ Server = 'avm01.domain.local';  CredentialSecret = 'GI-AppVol'; SkipCertificateCheck = $false
                  TestPackages = @('Notepad++')            # packages assigned to the test pool's computer OU
                  # API paths differ between App Volumes releases: confirm against your AVM's API docs
                  Endpoints = @{ Session = '/cv_api/sessions'; OnlineEntities = '/cv_api/online_entities'; Attachments = '/app_volumes/app_attachments' } }

  # The golden image VM and what runs inside it
  GoldenImage = @{
    VmName            = 'W11-GI-01'
    GuestCredentialSecret = 'GI-GuestAdmin'
    ScriptPathInGuest = 'C:\ProgramData\VDI\VDI-GoldenImage.ps1'
    Actions           = @('VmTools','Horizon','DEM','AppVolumes','FSLogix','MsTeams')   # run with -Unattended after updates
    WindowsUpdate     = @{ Enabled = $true; MaxPasses = 5 }
    FinalizeAction    = 'Finalize'
    PowerOffTimeoutMin = 90
  }

  # Test pool receives every new snapshot; production pools only after approval
  Pools = @{
    Test       = @{ Name = 'TST-W11'; LogoffPolicy = 'FORCE_LOGOFF' }
    Production = @( @{ Name = 'PRD-W11'; LogoffPolicy = 'WAIT_FOR_LOGOFF' } )
    PushTimeoutMin = 120
  }

  # Post-push validation on the test pool
  Validation = @{
    GuestSampleCount = 2
    RequiredServices = @('wsnm','svservice','frxsvc')
    MachineReadyTimeoutMin = 60
  }

  # Snapshot retention (Prune = $false => report only)
  # ProtectAncestors: never delete a parent of an in-use snapshot (Horizon tracks snapshots by path)
  Snapshots = @{ Keep = 3; MaxChainDepth = 10; Prune = $false; ProtectAncestors = $true }

  # Production promotion behaviour
  Promotion = @{
    AutoPromote = $false
    MaintenanceWindow = @{ Days = @('Saturday'); StartTime = '22:00' }   # next window used when no -StartTime given
    PipelineSchedule  = @{ Day = 'Tuesday'; Time = '20:00' }               # weekly start of the pipeline scheduled task
  }

  # Run report email
  Email = @{ Enabled = $false; SmtpServer = 'smtp.domain.local'; Port = 25; From = 'vdi-pipeline@domain.local'; To = @('vdi-team@domain.local'); UseSsl = $false }

  # Pode web dashboard
  Dashboard = @{ Port = 8443; CertificateThumbprint = ''; ViewerGroup = 'DOMAIN\VDI-Pipeline-Viewers'; ApproverGroup = 'DOMAIN\VDI-Pipeline-Approvers'; AdminGroup = 'DOMAIN\VDI-Pipeline-Admins'; RefreshSeconds = 20 }
}
