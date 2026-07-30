<#
.SYNOPSIS
    WPF GUI manager and execution console for Share Migration.
.DESCRIPTION
    Opens a Windows Presentation Foundation GUI that allows editing the share migration
    config visually and running migration modes interactively. Supports:
    - All top-level ShareMigration fields
    - Migration pair management (add/edit/remove)
    - Preflight settings
    - Credential selection from available .cred files
    - Save / Save As / Load
    - Validation before save
    - Interactive execution of all migration modes with live console output
.EXAMPLE
    .\Start-ShareMigManager.ps1
    # Opens the current Config_shareMig.json in the GUI

    .\Start-ShareMigManager.ps1 -Path .\Config_shareMig.json.bak
    # Opens a specific config file
.NOTES
    Requires Windows (WPF). PowerShell 5.1 or 7+ with Windows Forms/WPF support.
#>
[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if (-not $Path) {
    $Path = Join-Path $workspaceRoot 'Config_shareMig.json'
}

# --- Load available credentials ---
$credDir = Join-Path $workspaceRoot 'credentials'
$availableCreds = @('')
if (Test-Path $credDir) {
    $availableCreds += Get-ChildItem -Path $credDir -Filter '*.cred' | 
        ForEach-Object { $_.BaseName } | Sort-Object
}

# --- Load available clusters ---
$configPath = Join-Path $workspaceRoot 'config.json'
$clusterNames = @('')
if (Test-Path $configPath) {
    $globalConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $clusterNames += $globalConfig.ONTAP_Clusters | ForEach-Object { $_.cluster }
}

# --- XAML GUI ---
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Share Migration Manager" Height="750" Width="900"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize">
    <Window.Resources>
        <Style TargetType="Label">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Padding" Value="3"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Padding" Value="3"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Margin" Value="4"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <DockPanel>
        <!-- Toolbar -->
        <ToolBar DockPanel.Dock="Top">
            <Button Name="btnLoad" Content="📂 Load" Padding="8,4" Margin="2"/>
            <Button Name="btnSave" Content="💾 Save" Padding="8,4" Margin="2"/>
            <Button Name="btnSaveAs" Content="💾 Save As..." Padding="8,4" Margin="2"/>
            <Separator/>
            <Button Name="btnValidate" Content="✔ Validate" Padding="8,4" Margin="2"/>
            <Separator/>
            <Button Name="btnNewCred" Content="🔑 New Credential" Padding="8,4" Margin="2"/>
            <Button Name="btnSetCred" Content="🔑 Set Password" Padding="8,4" Margin="2" ToolTip="Update password for an existing credential"/>
            <Separator/>
            <TextBlock Name="txtFilePath" VerticalAlignment="Center" Margin="8,0" Foreground="Gray" FontSize="11"/>
        </ToolBar>
        
        <!-- Status bar -->
        <StatusBar DockPanel.Dock="Bottom">
            <TextBlock Name="txtStatus" Text="Ready"/>
        </StatusBar>
        
        <!-- Main content -->
        <TabControl Margin="5">
            <!-- Domain Settings Tab -->
            <TabItem Header="Domain Settings">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="200"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="20"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        
                        <!-- Source -->
                        <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="Source Domain" FontWeight="Bold" FontSize="14" Margin="0,5,0,5"/>
                        <Label Grid.Row="1" Grid.Column="0" Content="Domain (FQDN)"/>
                        <TextBox Grid.Row="1" Grid.Column="1" Name="txtSrcDomain"/>
                        <Label Grid.Row="2" Grid.Column="0" Content="Domain Controller(s)"/>
                        <TextBox Grid.Row="2" Grid.Column="1" Name="txtSrcDC" ToolTip="Comma-separated IPs. ONTAP requires IPs, not hostnames."/>
                        <Label Grid.Row="3" Grid.Column="0" Content="Credential Name"/>
                        <ComboBox Grid.Row="3" Grid.Column="1" Name="cmbSrcCredName" IsEditable="True"/>
                        <Label Grid.Row="4" Grid.Column="0" Content="Domain User (UPN)"/>
                        <TextBox Grid.Row="4" Grid.Column="1" Name="txtSrcDomainUser" IsReadOnly="True" Background="#F0F0F0" ToolTip="Auto-resolved from credential registry"/>
                        <Label Grid.Row="5" Grid.Column="0" Content="DNS Servers"/>
                        <TextBox Grid.Row="5" Grid.Column="1" Name="txtSrcDns" ToolTip="Comma-separated IPs"/>
                        <Label Grid.Row="6" Grid.Column="0" Content="DNS Domains"/>
                        <TextBox Grid.Row="6" Grid.Column="1" Name="txtSrcDnsDomains" ToolTip="Comma-separated domain suffixes (e.g. source.example.invalid)"/>
                        
                        <!-- Destination -->
                        <TextBlock Grid.Row="8" Grid.ColumnSpan="2" Text="Destination Domain" FontWeight="Bold" FontSize="14" Margin="0,5,0,5"/>
                        <Label Grid.Row="9" Grid.Column="0" Content="Domain (FQDN)"/>
                        <TextBox Grid.Row="9" Grid.Column="1" Name="txtDestDomain"/>
                        <Label Grid.Row="10" Grid.Column="0" Content="Domain Controller"/>
                        <TextBox Grid.Row="10" Grid.Column="1" Name="txtDestDC" ToolTip="IP address. ONTAP requires IPs, not hostnames."/>
                        <Label Grid.Row="11" Grid.Column="0" Content="Credential Name"/>
                        <ComboBox Grid.Row="11" Grid.Column="1" Name="cmbDestCredName" IsEditable="True"/>
                        <Label Grid.Row="12" Grid.Column="0" Content="Domain User (UPN)"/>
                        <TextBox Grid.Row="12" Grid.Column="1" Name="txtDestDomainUser" IsReadOnly="True" Background="#F0F0F0" ToolTip="Auto-resolved from credential registry"/>
                        <Label Grid.Row="13" Grid.Column="0" Content="DNS Servers"/>
                        <TextBox Grid.Row="13" Grid.Column="1" Name="txtDestDns" ToolTip="Comma-separated IPs"/>
                        <Label Grid.Row="14" Grid.Column="0" Content="DNS Domains"/>
                        <TextBox Grid.Row="14" Grid.Column="1" Name="txtDestDnsDomains" ToolTip="Comma-separated domain suffixes"/>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            
            <!-- ONTAP Settings Tab -->
            <TabItem Header="ONTAP Settings">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="200"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="20"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        
                        <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="Source CIFS Settings" FontWeight="Bold" FontSize="14" Margin="0,5,0,5"/>
                        <Label Grid.Row="1" Grid.Column="0" Content="Default Site Name"/>
                        <TextBox Grid.Row="1" Grid.Column="1" Name="txtSrcSite" ToolTip="AD site for CIFS server (used by Rollback)"/>
                        <Label Grid.Row="2" Grid.Column="0" Content="Discovery Mode"/>
                        <ComboBox Grid.Row="2" Grid.Column="1" Name="cmbSrcDiscovery" ToolTip="DC discovery: site=AD site, none=preferred DCs only, all=all DCs">
                            <ComboBoxItem Content=""/>
                            <ComboBoxItem Content="site"/>
                            <ComboBoxItem Content="none"/>
                            <ComboBoxItem Content="all"/>
                        </ComboBox>
                        <Label Grid.Row="3" Grid.Column="0" Content="Organizational Unit"/>
                        <TextBox Grid.Row="3" Grid.Column="1" Name="txtSrcOU" ToolTip="OU for CIFS computer object (e.g. CN=Computers). Used by Rollback."/>
                        <Label Grid.Row="4" Grid.Column="0" Content="NetBIOS Alias"/>
                        <TextBox Grid.Row="4" Grid.Column="1" Name="txtSrcNetbios" ToolTip="Source CIFS server alias (used by Rollback)"/>
                        
                        <TextBlock Grid.Row="6" Grid.ColumnSpan="2" Text="Destination CIFS Settings" FontWeight="Bold" FontSize="14" Margin="0,5,0,5"/>
                        <Label Grid.Row="7" Grid.Column="0" Content="Default Site Name"/>
                        <TextBox Grid.Row="7" Grid.Column="1" Name="txtDestSite" ToolTip="AD site for CIFS server (used by DomainMigration)"/>
                        <Label Grid.Row="8" Grid.Column="0" Content="Discovery Mode"/>
                        <ComboBox Grid.Row="8" Grid.Column="1" Name="cmbDestDiscovery" ToolTip="DC discovery: site=AD site, none=preferred DCs only, all=all DCs">
                            <ComboBoxItem Content=""/>
                            <ComboBoxItem Content="site"/>
                            <ComboBoxItem Content="none"/>
                            <ComboBoxItem Content="all"/>
                        </ComboBox>
                        <Label Grid.Row="9" Grid.Column="0" Content="Organizational Unit"/>
                        <TextBox Grid.Row="9" Grid.Column="1" Name="txtDestOU" ToolTip="Default OU for CIFS computer object. Per-pair DestinationOU overrides this."/>
                        <Label Grid.Row="10" Grid.Column="0" Content="NetBIOS Alias"/>
                        <TextBox Grid.Row="10" Grid.Column="1" Name="txtDestNetbios" ToolTip="Destination CIFS server alias (used by DomainMigration)"/>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            
            <!-- Options Tab -->
            <TabItem Header="Options">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10">
                    <StackPanel>
                        <TextBlock Text="DFS &amp; Group Settings" FontWeight="Bold" FontSize="14" Margin="0,5,0,10"/>
                        <CheckBox Name="chkSkipDfs" Content="Skip DFS handling"/>
                        <CheckBox Name="chkCreateDfsLinks" Content="Create destination DFS links"/>
                        <StackPanel Orientation="Horizontal" Margin="0,5">
                            <Label Content="DFS Root Path" Width="180"/>
                            <TextBox Name="txtDfsRoot" Width="300"/>
                        </StackPanel>
                        <Separator Margin="0,10"/>
                        <CheckBox Name="chkSkipGroupCreation" Content="Skip AD group creation (replay ACLs as-is)"/>
                        <StackPanel Orientation="Horizontal" Margin="0,5">
                            <Label Content="Group Name Prefix" Width="180"/>
                            <TextBox Name="txtGroupPrefix" Width="200"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,5">
                            <Label Content="Source Group OU" Width="180"/>
                            <TextBox Name="txtSrcGroupOu" Width="400"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,5">
                            <Label Content="Destination Group OU" Width="180"/>
                            <TextBox Name="txtDestGroupOu" Width="400"/>
                        </StackPanel>
                        <Separator Margin="0,10"/>
                        <TextBlock Text="Paths &amp; Approvals" FontWeight="Bold" FontSize="14" Margin="0,5,0,10"/>
                        <StackPanel Orientation="Horizontal" Margin="0,5">
                            <Label Content="Export Root" Width="180"/>
                            <TextBox Name="txtExportRoot" Width="400"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,5">
                            <Label Content="Log Root" Width="180"/>
                            <TextBox Name="txtLogRoot" Width="400"/>
                        </StackPanel>
                        <CheckBox Name="chkRequirePreflight" Content="Require preflight approval before migration"/>
                        <CheckBox Name="chkAutoRegisterSPN" Content="Auto-register SPNs for NetBIOS aliases" ToolTip="When checked, registers SPNs via Set-ADComputer using the configured domain credentials. When unchecked, logs SETSPN commands as warnings for manual execution. Only applies when NetBIOS aliases are configured."/>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>
            
            <!-- Preflight Tab -->
            <TabItem Header="Preflight">
                <StackPanel Margin="10">
                    <TextBlock Text="Preflight Test Settings" FontWeight="Bold" FontSize="14" Margin="0,5,0,10"/>
                    <TextBlock Text="These settings define where the preflight test share and group are created." Foreground="Gray" Margin="0,0,0,10"/>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="150"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Label Grid.Row="0" Grid.Column="0" Content="Cluster"/>
                        <ComboBox Grid.Row="0" Grid.Column="1" Name="cmbPfCluster" IsEditable="True" Width="350" HorizontalAlignment="Left"/>
                        <Label Grid.Row="1" Grid.Column="0" Content="Vserver"/>
                        <TextBox Grid.Row="1" Grid.Column="1" Name="txtPfVserver" Width="250" HorizontalAlignment="Left"/>
                        <Label Grid.Row="2" Grid.Column="0" Content="Share Name"/>
                        <TextBox Grid.Row="2" Grid.Column="1" Name="txtPfShareName" Width="250" HorizontalAlignment="Left"/>
                        <Label Grid.Row="3" Grid.Column="0" Content="Share Path"/>
                        <TextBox Grid.Row="3" Grid.Column="1" Name="txtPfSharePath" Width="350" HorizontalAlignment="Left"/>
                        <Label Grid.Row="4" Grid.Column="0" Content="Group Name"/>
                        <TextBox Grid.Row="4" Grid.Column="1" Name="txtPfGroupName" Width="250" HorizontalAlignment="Left"/>
                    </Grid>
                </StackPanel>
            </TabItem>
            
            <!-- Pairs Tab -->
            <TabItem Header="Migration Pairs">
                <DockPanel Margin="5">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,5">
                        <Button Name="btnAddPair" Content="➕ Add Pair" Padding="8,4" Margin="2"/>
                        <Button Name="btnEditPair" Content="✏️ Edit" Padding="8,4" Margin="2"/>
                        <Button Name="btnRemovePair" Content="❌ Remove" Padding="8,4" Margin="2"/>
                        <Button Name="btnDuplicatePair" Content="📋 Duplicate" Padding="8,4" Margin="2"/>
                    </StackPanel>
                    <DataGrid Name="dgPairs" AutoGenerateColumns="False" IsReadOnly="True" 
                              SelectionMode="Single" CanUserAddRows="False" CanUserDeleteRows="False"
                              HeadersVisibility="Column" GridLinesVisibility="Horizontal">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="150"/>
                            <DataGridTextColumn Header="Source Cluster" Binding="{Binding SourceCluster}" Width="150"/>
                            <DataGridTextColumn Header="Source Vserver" Binding="{Binding SourceVserver}" Width="120"/>
                            <DataGridTextColumn Header="Dest Cluster" Binding="{Binding DestinationCluster}" Width="150"/>
                            <DataGridTextColumn Header="Dest Vserver" Binding="{Binding DestinationVserver}" Width="120"/>
                            <DataGridTextColumn Header="Filter" Binding="{Binding ShareFilter}" Width="80"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
            
            <!-- Raw JSON Tab -->
            <TabItem Header="Raw JSON">
                <DockPanel Margin="5">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,5">
                        <Button Name="btnApplyJson" Content="Apply JSON Changes" Padding="8,4" Margin="2"/>
                        <Button Name="btnRefreshJson" Content="Refresh from Form" Padding="8,4" Margin="2"/>
                    </StackPanel>
                    <TextBox Name="txtRawJson" AcceptsReturn="True" AcceptsTab="True"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             FontFamily="Consolas" FontSize="12"/>
                </DockPanel>
            </TabItem>
            
            <!-- Run Tab -->
            <TabItem Header="▶ Run">
                <DockPanel Margin="5">
                    <!-- Controls bar -->
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,5">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Label Grid.Column="0" Content="Mode:" VerticalAlignment="Center"/>
                        <ComboBox Grid.Column="1" Name="cmbRunMode" Width="180" Margin="2" SelectedIndex="0">
                            <ComboBoxItem Content="TestCredentials"/>
                            <ComboBoxItem Content="Export"/>
                            <ComboBoxItem Content="Preflight"/>
                            <ComboBoxItem Content="Import"/>
                            <ComboBoxItem Content="Sync"/>
                            <ComboBoxItem Content="DomainMigration"/>
                            <ComboBoxItem Content="Rollback"/>
                            <ComboBoxItem Content="ResetCifsPassword"/>
                            <ComboBoxItem Content="SetSPN"/>
                        </ComboBox>
                        <Label Grid.Column="2" Content="Target:" VerticalAlignment="Center" Margin="10,0,0,0"/>
                        <ComboBox Grid.Column="3" Name="cmbRunTarget" Width="120" Margin="2" SelectedIndex="2">
                            <ComboBoxItem Content="Source"/>
                            <ComboBoxItem Content="Destination"/>
                            <ComboBoxItem Content="Both"/>
                        </ComboBox>
                        <Button Grid.Column="5" Name="btnRun" Content="▶ Run" Padding="12,4" Margin="2" FontWeight="Bold" Background="#4CAF50" Foreground="White"/>
                        <Button Grid.Column="6" Name="btnRunStop" Content="⏹ Stop" Padding="12,4" Margin="2" IsEnabled="False" Background="#f44336" Foreground="White"/>
                        <Button Grid.Column="7" Name="btnRunClear" Content="🗑 Clear" Padding="8,4" Margin="2"/>
                    </Grid>
                    <!-- Status bar for run -->
                    <Grid DockPanel.Dock="Bottom" Margin="0,5,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Name="txtRunStatus" Text="Idle" VerticalAlignment="Center" Margin="5,0"/>
                        <TextBlock Grid.Column="1" Name="txtRunElapsed" Text="" VerticalAlignment="Center" Margin="10,0" Foreground="Gray"/>
                        <Button Grid.Column="2" Name="btnOpenLog" Content="📄 Open Log" Padding="8,4" Margin="2"/>
                        <Button Grid.Column="3" Name="btnOpenExports" Content="📁 Exports" Padding="8,4" Margin="2"/>
                    </Grid>
                    <!-- Console output -->
                    <TextBox Name="txtRunConsole" IsReadOnly="True"
                             AcceptsReturn="True" TextWrapping="Wrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             FontFamily="Consolas" FontSize="11"
                             Background="#1E1E1E" Foreground="#CCCCCC"
                             BorderThickness="1" BorderBrush="#333333"/>
                </DockPanel>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
"@

# --- Create Window ---
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# --- Get controls ---
$controls = @{}
$xaml.SelectNodes('//*[@Name]') | ForEach-Object {
    $controls[$_.Name] = $window.FindName($_.Name)
}

# --- State ---
$script:ConfigPath = $Path
$script:Config = $null
$script:Pairs = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

# --- Load credential registry ---
$script:CredRegistry = @{}
$registryFile = Join-Path $workspaceRoot 'credentials\credentials.json'
if (Test-Path -LiteralPath $registryFile) {
    $regJson = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
    foreach ($prop in $regJson.PSObject.Properties) {
        $script:CredRegistry[$prop.Name] = $prop.Value.UserName
    }
}

function Reload-CredRegistry {
    $script:CredRegistry = @{}
    $rf = Join-Path $workspaceRoot 'credentials\credentials.json'
    if (Test-Path -LiteralPath $rf) {
        $rj = Get-Content -LiteralPath $rf -Raw | ConvertFrom-Json
        foreach ($prop in $rj.PSObject.Properties) {
            $script:CredRegistry[$prop.Name] = $prop.Value.UserName
        }
    }
}

# --- Populate combo boxes ---
foreach ($cred in $availableCreds) {
    $controls['cmbSrcCredName'].Items.Add($cred) | Out-Null
    $controls['cmbDestCredName'].Items.Add($cred) | Out-Null
}
foreach ($cluster in $clusterNames) {
    $controls['cmbPfCluster'].Items.Add($cluster) | Out-Null
}

# --- Auto-fill username from credential registry (always update — field is read-only) ---
$controls['cmbSrcCredName'].Add_SelectionChanged({
    $credName = $controls['cmbSrcCredName'].Text
    if ($credName -and $script:CredRegistry.ContainsKey($credName)) {
        $controls['txtSrcDomainUser'].Text = $script:CredRegistry[$credName]
    } elseif (-not $credName) {
        $controls['txtSrcDomainUser'].Text = ''
    }
})
$controls['cmbSrcCredName'].Add_LostFocus({
    $credName = $controls['cmbSrcCredName'].Text
    if ($credName -and $script:CredRegistry.ContainsKey($credName)) {
        $controls['txtSrcDomainUser'].Text = $script:CredRegistry[$credName]
    }
})
$controls['cmbDestCredName'].Add_SelectionChanged({
    $credName = $controls['cmbDestCredName'].Text
    if ($credName -and $script:CredRegistry.ContainsKey($credName)) {
        $controls['txtDestDomainUser'].Text = $script:CredRegistry[$credName]
    } elseif (-not $credName) {
        $controls['txtDestDomainUser'].Text = ''
    }
})
$controls['cmbDestCredName'].Add_LostFocus({
    $credName = $controls['cmbDestCredName'].Text
    if ($credName -and $script:CredRegistry.ContainsKey($credName)) {
        $controls['txtDestDomainUser'].Text = $script:CredRegistry[$credName]
    }
})

# --- Helper functions ---
function Load-ConfigToForm {
    param($cfg)
    $sm = $cfg.ShareMigration
    
    # Domain
    $controls['txtSrcDomain'].Text = $sm.Domain
    $controls['txtSrcDC'].Text = if ($sm.SourceDomainController -is [array]) { $sm.SourceDomainController -join ', ' } else { "$($sm.SourceDomainController)" }
    $controls['txtSrcSite'].Text = "$($sm.SourceDefaultSiteName)"
    $controls['cmbSrcDiscovery'].Text = "$($sm.SourceDiscoveryMode)"
    $controls['cmbSrcCredName'].Text = "$($sm.SourceDomainCredentialName)"
    $controls['txtSrcDomainUser'].Text = "$($sm.SourceDomainUser)"
    $controls['txtSrcDns'].Text = if ($sm.SourceDnsServers -is [array]) { $sm.SourceDnsServers -join ', ' } else { "$($sm.SourceDnsServers)" }
    
    $controls['txtDestDomain'].Text = "$($sm.DestinationDomain)"
    $controls['txtDestDC'].Text = "$($sm.DestinationDomainController)"
    $controls['txtDestSite'].Text = "$($sm.DestinationDefaultSiteName)"
    $controls['cmbDestDiscovery'].Text = "$($sm.DestinationDiscoveryMode)"
    $controls['cmbDestCredName'].Text = "$($sm.DestinationDomainCredentialName)"
    $controls['txtDestDomainUser'].Text = "$($sm.DestinationDomainUser)"
    $controls['txtDestDns'].Text = if ($sm.DestinationDnsServers -is [array]) { $sm.DestinationDnsServers -join ', ' } else { "$($sm.DestinationDnsServers)" }
    $controls['txtDestNetbios'].Text = "$($sm.DestinationNetbiosAlias)"
    $controls['txtDestOU'].Text = "$($sm.DestinationOrganizationalUnit)"
    
    # Options
    $controls['chkSkipDfs'].IsChecked = [bool]$sm.SkipDFS
    $controls['chkCreateDfsLinks'].IsChecked = [bool]$sm.CreateDestinationDFSLinks
    $controls['txtDfsRoot'].Text = "$($sm.DfsRoot)"
    $controls['chkSkipGroupCreation'].IsChecked = [bool]$sm.SkipGroupCreation
    $controls['txtGroupPrefix'].Text = "$($sm.GroupNamePrefix)"
    $controls['txtSrcGroupOu'].Text = "$($sm.SourceGroupOuPath)"
    $controls['txtDestGroupOu'].Text = "$($sm.DestinationGroupOuPath)"
    $controls['txtExportRoot'].Text = "$($sm.ExportRoot)"
    $controls['txtLogRoot'].Text = "$($sm.LogRoot)"
    $controls['chkRequirePreflight'].IsChecked = [bool]$sm.RequirePreflightApproval
    $controls['chkAutoRegisterSPN'].IsChecked = [bool]$sm.AutoRegisterSPN
    $controls['txtSrcOU'].Text = "$($sm.SourceOrganizationalUnit)"
    $controls['txtSrcDnsDomains'].Text = if ($sm.SourceDnsDomains -is [array]) { $sm.SourceDnsDomains -join ', ' } else { "$($sm.SourceDnsDomains)" }
    $controls['txtSrcNetbios'].Text = "$($sm.SourceNetbiosAlias)"
    $controls['txtDestDnsDomains'].Text = if ($sm.DestinationDnsDomains -is [array]) { $sm.DestinationDnsDomains -join ', ' } else { "$($sm.DestinationDnsDomains)" }
    
    # Preflight
    if ($sm.Preflight) {
        $controls['cmbPfCluster'].Text = "$($sm.Preflight.Cluster)"
        $controls['txtPfVserver'].Text = "$($sm.Preflight.Vserver)"
        $controls['txtPfShareName'].Text = "$($sm.Preflight.ShareName)"
        $controls['txtPfSharePath'].Text = "$($sm.Preflight.SharePath)"
        $controls['txtPfGroupName'].Text = "$($sm.Preflight.GroupName)"
    }
    
    # Pairs
    $script:Pairs.Clear()
    if ($sm.Pairs) {
        foreach ($p in $sm.Pairs) {
            $script:Pairs.Add([pscustomobject]@{
                Name                          = $p.Name
                SourceCluster                 = $p.SourceCluster
                SourceVserver                 = $p.SourceVserver
                SourceCredentialName          = $p.SourceCredentialName
                SourceCredentialUserName      = $p.SourceCredentialUserName
                DestinationCluster            = $p.DestinationCluster
                DestinationVserver            = $p.DestinationVserver
                DestinationCredentialName     = $p.DestinationCredentialName
                DestinationCredentialUserName = $p.DestinationCredentialUserName
                DestinationCifsServerName     = $p.DestinationCifsServerName
                DestinationOU                 = $p.DestinationOU
                CreateDFSLink                 = [bool]$p.CreateDFSLink
                ShareFilter                   = $p.ShareFilter
            })
        }
    }
    $controls['dgPairs'].ItemsSource = $script:Pairs
    
    # Raw JSON
    $controls['txtRawJson'].Text = $cfg | ConvertTo-Json -Depth 10
    
    $controls['txtFilePath'].Text = $script:ConfigPath
    $controls['txtStatus'].Text = "Loaded: $($script:ConfigPath)"
}

function Build-ConfigFromForm {
    # Parse comma-separated fields to arrays
    $srcDcArray = @($controls['txtSrcDC'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $srcDnsArray = @($controls['txtSrcDns'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $destDnsArray = @($controls['txtDestDns'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $srcDnsDomainsArray = @($controls['txtSrcDnsDomains'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $destDnsDomainsArray = @($controls['txtDestDnsDomains'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    
    # Source DC: single string or array based on count
    $srcDcValue = if ($srcDcArray.Count -eq 1) { $srcDcArray[0] } elseif ($srcDcArray.Count -gt 1) { $srcDcArray } else { @() }
    
    $pairsArray = @()
    foreach ($p in $script:Pairs) {
        $pairsArray += [ordered]@{
            '_comment'                      = ''
            'Name'                          = $p.Name
            'SourceCluster'                 = $p.SourceCluster
            'SourceVserver'                 = $p.SourceVserver
            'SourceCredentialName'          = $p.SourceCredentialName
            'SourceCredentialUserName'      = $p.SourceCredentialUserName
            'DestinationCluster'            = $p.DestinationCluster
            'DestinationVserver'            = $p.DestinationVserver
            'DestinationCredentialName'     = $p.DestinationCredentialName
            'DestinationCredentialUserName' = $p.DestinationCredentialUserName
            'DestinationCifsServerName'     = $p.DestinationCifsServerName
            'DestinationOU'                 = $p.DestinationOU
            'CreateDFSLink'                 = [bool]$p.CreateDFSLink
            'ShareFilter'                   = $p.ShareFilter
        }
    }
    
    $config = [ordered]@{
        '_comment' = "Share migration config. Managed by Start-ShareMigManager.ps1"
        'ShareMigration' = [ordered]@{
            'Domain'                          = $controls['txtSrcDomain'].Text
            'SourceDomainController'          = $srcDcValue
            'SourceDefaultSiteName'           = if ($controls['txtSrcSite'].Text) { $controls['txtSrcSite'].Text } else { $null }
            'SourceDiscoveryMode'             = if ($controls['cmbSrcDiscovery'].Text) { $controls['cmbSrcDiscovery'].Text } else { $null }
            'SourceOrganizationalUnit'        = if ($controls['txtSrcOU'].Text) { $controls['txtSrcOU'].Text } else { $null }
            'SourceDomainCredentialName'      = $controls['cmbSrcCredName'].Text
            'SourceDomainUser'                = $controls['txtSrcDomainUser'].Text
            'SourceDnsServers'                = $srcDnsArray
            'SourceDnsDomains'                = $srcDnsDomainsArray
            'SourceNetbiosAlias'              = if ($controls['txtSrcNetbios'].Text) { $controls['txtSrcNetbios'].Text } else { $null }
            'DestinationDomain'               = $controls['txtDestDomain'].Text
            'DestinationDomainController'     = $controls['txtDestDC'].Text
            'DestinationDefaultSiteName'      = if ($controls['txtDestSite'].Text) { $controls['txtDestSite'].Text } else { $null }
            'DestinationDiscoveryMode'        = if ($controls['cmbDestDiscovery'].Text) { $controls['cmbDestDiscovery'].Text } else { $null }
            'DestinationOrganizationalUnit'   = if ($controls['txtDestOU'].Text) { $controls['txtDestOU'].Text } else { $null }
            'DestinationDomainCredentialName' = $controls['cmbDestCredName'].Text
            'DestinationDomainUser'           = $controls['txtDestDomainUser'].Text
            'DestinationDnsServers'           = $destDnsArray
            'DestinationDnsDomains'           = $destDnsDomainsArray
            'DestinationNetbiosAlias'         = if ($controls['txtDestNetbios'].Text) { $controls['txtDestNetbios'].Text } else { $null }
            'SkipDFS'                         = [bool]$controls['chkSkipDfs'].IsChecked
            'CreateDestinationDFSLinks'       = [bool]$controls['chkCreateDfsLinks'].IsChecked
            'DfsRoot'                         = $controls['txtDfsRoot'].Text
            'SkipGroupCreation'               = [bool]$controls['chkSkipGroupCreation'].IsChecked
            'SourceGroupOuPath'               = $controls['txtSrcGroupOu'].Text
            'DestinationGroupOuPath'          = $controls['txtDestGroupOu'].Text
            'GroupNamePrefix'                 = $controls['txtGroupPrefix'].Text
            'ExportRoot'                      = $controls['txtExportRoot'].Text
            'LogRoot'                         = $controls['txtLogRoot'].Text
            'RequirePreflightApproval'        = [bool]$controls['chkRequirePreflight'].IsChecked
            'AutoRegisterSPN'                 = [bool]$controls['chkAutoRegisterSPN'].IsChecked
            'Preflight'                       = [ordered]@{
                'Cluster'   = $controls['cmbPfCluster'].Text
                'Vserver'   = $controls['txtPfVserver'].Text
                'ShareName' = $controls['txtPfShareName'].Text
                'SharePath' = $controls['txtPfSharePath'].Text
                'GroupName' = $controls['txtPfGroupName'].Text
            }
            'Pairs'                           = $pairsArray
        }
    }
    
    return $config
}

function Save-Config {
    param([string]$TargetPath)
    
    $config = Build-ConfigFromForm
    $json = $config | ConvertTo-Json -Depth 10
    $json | Set-Content -LiteralPath $TargetPath -Encoding utf8
    $script:ConfigPath = $TargetPath
    $controls['txtFilePath'].Text = $TargetPath
    $controls['txtStatus'].Text = "Saved: $TargetPath ($(Get-Date -Format 'HH:mm:ss'))"
    $controls['txtRawJson'].Text = $json
}

# --- Pair Editor Dialog ---
function Show-PairEditor {
    param($Pair)
    
    $isNew = ($null -eq $Pair)
    if ($isNew) {
        $Pair = [pscustomobject]@{
            Name = ''; SourceCluster = ''; SourceVserver = ''
            SourceCredentialName = ''; SourceCredentialUserName = ''
            DestinationCluster = ''; DestinationVserver = ''
            DestinationCredentialName = ''; DestinationCredentialUserName = ''
            DestinationCifsServerName = ''; DestinationOU = ''
            CreateDFSLink = $false; ShareFilter = '*'
        }
    }
    
    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="$(if ($isNew) {'Add'} else {'Edit'}) Migration Pair" Height="450" Width="500"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="10">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="180"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <Label Grid.Row="0" Grid.Column="0" Content="Pair Name"/>
        <TextBox Grid.Row="0" Grid.Column="1" Name="txtPairName" Text="$($Pair.Name)"/>
        <Label Grid.Row="1" Grid.Column="0" Content="Source Cluster"/>
        <TextBox Grid.Row="1" Grid.Column="1" Name="txtPairSrcCluster" Text="$($Pair.SourceCluster)"/>
        <Label Grid.Row="2" Grid.Column="0" Content="Source Vserver"/>
        <TextBox Grid.Row="2" Grid.Column="1" Name="txtPairSrcVserver" Text="$($Pair.SourceVserver)"/>
        <Label Grid.Row="3" Grid.Column="0" Content="Source Credential"/>
        <ComboBox Grid.Row="3" Grid.Column="1" Name="cmbPairSrcCred" IsEditable="True" Text="$($Pair.SourceCredentialName)"/>
        <Label Grid.Row="4" Grid.Column="0" Content="Source Username"/>
        <TextBox Grid.Row="4" Grid.Column="1" Name="txtPairSrcUser" Text="$($Pair.SourceCredentialUserName)" IsReadOnly="True" Background="#F0F0F0" ToolTip="Auto-resolved from credential registry"/>
        <Label Grid.Row="5" Grid.Column="0" Content="Destination Cluster"/>
        <TextBox Grid.Row="5" Grid.Column="1" Name="txtPairDestCluster" Text="$($Pair.DestinationCluster)"/>
        <Label Grid.Row="6" Grid.Column="0" Content="Destination Vserver"/>
        <TextBox Grid.Row="6" Grid.Column="1" Name="txtPairDestVserver" Text="$($Pair.DestinationVserver)"/>
        <Label Grid.Row="7" Grid.Column="0" Content="Destination Credential"/>
        <ComboBox Grid.Row="7" Grid.Column="1" Name="cmbPairDestCred" IsEditable="True" Text="$($Pair.DestinationCredentialName)"/>
        <Label Grid.Row="8" Grid.Column="0" Content="Destination Username"/>
        <TextBox Grid.Row="8" Grid.Column="1" Name="txtPairDestUser" Text="$($Pair.DestinationCredentialUserName)" IsReadOnly="True" Background="#F0F0F0" ToolTip="Auto-resolved from credential registry"/>
        <Label Grid.Row="9" Grid.Column="0" Content="Dest CIFS Server Name"/>
        <TextBox Grid.Row="9" Grid.Column="1" Name="txtPairDestCifs" Text="$($Pair.DestinationCifsServerName)"/>
        <Label Grid.Row="10" Grid.Column="0" Content="Destination OU"/>
        <TextBox Grid.Row="10" Grid.Column="1" Name="txtPairDestOU" Text="$($Pair.DestinationOU)"/>
        <Label Grid.Row="11" Grid.Column="0" Content="Share Filter"/>
        <TextBox Grid.Row="11" Grid.Column="1" Name="txtPairFilter" Text="$($Pair.ShareFilter)"/>
        <CheckBox Grid.Row="12" Grid.Column="1" Name="chkPairDfs" Content="Create DFS Link" IsChecked="$(if($Pair.CreateDFSLink){'True'}else{'False'})"/>
        
        <StackPanel Grid.Row="14" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnPairOk" Content="OK" Width="80" Padding="4" Margin="5" IsDefault="True"/>
            <Button Name="btnPairCancel" Content="Cancel" Width="80" Padding="4" Margin="5" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    
    $dlgReader = [System.Xml.XmlNodeReader]::new($dlgXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.Owner = $window
    
    # Populate credential ComboBoxes
    $cmbPairSrc = $dlg.FindName('cmbPairSrcCred')
    $cmbPairDest = $dlg.FindName('cmbPairDestCred')
    foreach ($cred in $availableCreds) {
        $cmbPairSrc.Items.Add($cred) | Out-Null
        $cmbPairDest.Items.Add($cred) | Out-Null
    }
    
    # Auto-fill username from credential registry
    $txtPairSrcUser = $dlg.FindName('txtPairSrcUser')
    $txtPairDestUser = $dlg.FindName('txtPairDestUser')
    $registry = $script:CredRegistry
    
    $cmbPairSrc.Add_SelectionChanged({
        $credName = $cmbPairSrc.Text
        if ($credName -and $registry -and $registry.ContainsKey($credName)) {
            $txtPairSrcUser.Text = $registry[$credName]
        } elseif (-not $credName) {
            $txtPairSrcUser.Text = ''
        }
    }.GetNewClosure())
    $cmbPairSrc.Add_LostFocus({
        $credName = $cmbPairSrc.Text
        if ($credName -and $registry -and $registry.ContainsKey($credName)) {
            $txtPairSrcUser.Text = $registry[$credName]
        }
    }.GetNewClosure())
    $cmbPairDest.Add_SelectionChanged({
        $credName = $cmbPairDest.Text
        if ($credName -and $registry -and $registry.ContainsKey($credName)) {
            $txtPairDestUser.Text = $registry[$credName]
        } elseif (-not $credName) {
            $txtPairDestUser.Text = ''
        }
    }.GetNewClosure())
    $cmbPairDest.Add_LostFocus({
        $credName = $cmbPairDest.Text
        if ($credName -and $registry -and $registry.ContainsKey($credName)) {
            $txtPairDestUser.Text = $registry[$credName]
        }
    }.GetNewClosure())
    
    $dlg.FindName('btnPairOk').Add_Click({
        param($sender, $e)
        $sender.Tag = 'OK'
        $dlg.DialogResult = $true
    }.GetNewClosure())
    
    $dlg.FindName('btnPairCancel').Add_Click({
        param($sender, $e)
        $dlg.DialogResult = $false
    }.GetNewClosure())
    
    if ($dlg.ShowDialog()) {
        # Read values from dialog controls AFTER it closes (still in memory)
        return [pscustomobject]@{
            Name                          = $dlg.FindName('txtPairName').Text
            SourceCluster                 = $dlg.FindName('txtPairSrcCluster').Text
            SourceVserver                 = $dlg.FindName('txtPairSrcVserver').Text
            SourceCredentialName          = $dlg.FindName('cmbPairSrcCred').Text
            SourceCredentialUserName      = $dlg.FindName('txtPairSrcUser').Text
            DestinationCluster            = $dlg.FindName('txtPairDestCluster').Text
            DestinationVserver            = $dlg.FindName('txtPairDestVserver').Text
            DestinationCredentialName     = $dlg.FindName('cmbPairDestCred').Text
            DestinationCredentialUserName = $dlg.FindName('txtPairDestUser').Text
            DestinationCifsServerName     = $dlg.FindName('txtPairDestCifs').Text
            DestinationOU                 = $dlg.FindName('txtPairDestOU').Text
            CreateDFSLink                 = [bool]$dlg.FindName('chkPairDfs').IsChecked
            ShareFilter                   = $dlg.FindName('txtPairFilter').Text
        }
    }
    return $null
}

# --- Event handlers ---
$controls['btnLoad'].Add_Click({
    $ofd = [Microsoft.Win32.OpenFileDialog]@{
        Filter           = 'JSON files|*.json|All files|*.*'
        InitialDirectory = $workspaceRoot
        Title            = 'Load Share Migration Config'
    }
    if ($ofd.ShowDialog()) {
        try {
            $cfg = Get-Content -LiteralPath $ofd.FileName -Raw | ConvertFrom-Json
            $script:ConfigPath = $ofd.FileName
            Load-ConfigToForm -cfg $cfg
        } catch {
            [System.Windows.MessageBox]::Show("Failed to load: $($_.Exception.Message)", "Error", 'OK', 'Error')
        }
    }
})

$controls['btnSave'].Add_Click({
    try {
        Save-Config -TargetPath $script:ConfigPath
    } catch {
        [System.Windows.MessageBox]::Show("Failed to save: $($_.Exception.Message)", "Error", 'OK', 'Error')
    }
})

$controls['btnSaveAs'].Add_Click({
    $sfd = [Microsoft.Win32.SaveFileDialog]@{
        Filter           = 'JSON files|*.json|All files|*.*'
        InitialDirectory = $workspaceRoot
        FileName         = 'Config_shareMig.json'
        Title            = 'Save Share Migration Config As'
    }
    if ($sfd.ShowDialog()) {
        try {
            Save-Config -TargetPath $sfd.FileName
        } catch {
            [System.Windows.MessageBox]::Show("Failed to save: $($_.Exception.Message)", "Error", 'OK', 'Error')
        }
    }
})

$controls['btnValidate'].Add_Click({
    $errors = @()
    if (-not $controls['txtSrcDomain'].Text) { $errors += "Source domain is empty" }
    if (-not $controls['txtSrcDC'].Text) { $errors += "Source DC is empty" }
    if ($script:Pairs.Count -eq 0) { $errors += "No migration pairs defined" }
    foreach ($p in $script:Pairs) {
        if (-not $p.Name) { $errors += "Pair with empty name" }
        if (-not $p.SourceCluster) { $errors += "Pair '$($p.Name)': source cluster empty" }
        if (-not $p.SourceVserver) { $errors += "Pair '$($p.Name)': source vserver empty" }
    }
    
    if ($errors.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Config is valid!", "Validation", 'OK', 'Information')
        $controls['txtStatus'].Text = "Validation passed"
    } else {
        $msg = "Validation errors:`n`n" + ($errors -join "`n")
        [System.Windows.MessageBox]::Show($msg, "Validation Errors", 'OK', 'Warning')
        $controls['txtStatus'].Text = "Validation failed ($($errors.Count) errors)"
    }
})

$controls['btnNewCred'].Add_Click({
    # Build a small WPF dialog with Name + UserName + PasswordBox
    [xml]$credXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Create New Credential" Height="240" Width="450"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Label Content="Credential Name" Width="130"/>
            <TextBox Name="txtCredName" Width="260"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,8">
            <Label Content="Username (UPN)" Width="130"/>
            <TextBox Name="txtCredUserName" Width="260" ToolTip="e.g. admin, A_User@DOMAIN.LOCAL"/>
        </StackPanel>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,8">
            <Label Content="Password" Width="130"/>
            <PasswordBox Name="pwdCredPassword" Width="260"/>
        </StackPanel>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnCredOk" Content="Create" Width="80" Padding="4" Margin="5" IsDefault="True"/>
            <Button Name="btnCredCancel" Content="Cancel" Width="80" Padding="4" Margin="5" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $credReader = [System.Xml.XmlNodeReader]::new($credXaml)
    $credDlg = [System.Windows.Markup.XamlReader]::Load($credReader)
    $credDlg.Owner = $window

    $credDlg.FindName('btnCredOk').Add_Click({
        param($s,$ev)
        $credDlg.DialogResult = $true
    }.GetNewClosure())

    $credDlg.FindName('btnCredCancel').Add_Click({
        param($s,$ev)
        $credDlg.DialogResult = $false
    }.GetNewClosure())

    if ($credDlg.ShowDialog()) {
        $credName = $credDlg.FindName('txtCredName').Text.Trim()
        $credUser = $credDlg.FindName('txtCredUserName').Text.Trim()
        $credPwd  = $credDlg.FindName('pwdCredPassword').Password

        if (-not $credName) {
            [System.Windows.MessageBox]::Show('Credential name cannot be empty.', 'Error', 'OK', 'Error')
            return
        }
        if (-not $credPwd) {
            [System.Windows.MessageBox]::Show('Password cannot be empty.', 'Error', 'OK', 'Error')
            return
        }

        try {
            $credDir = Join-Path $workspaceRoot 'credentials'
            $keyFile = Join-Path $credDir 'aes.key'

            # Generate AES key if missing
            if (-not (Test-Path $keyFile)) {
                $aesKey = New-Object byte[] 32
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($aesKey)
                $aesKey | Set-Content -Path $keyFile -Force
            }
            $aesKey = Get-Content -Path $keyFile

            $outFile = Join-Path $credDir "$credName.cred"
            if (Test-Path $outFile) {
                $overwrite = [System.Windows.MessageBox]::Show("'$credName.cred' already exists. Overwrite?", 'Confirm', 'YesNo', 'Question')
                if ($overwrite -ne 'Yes') { return }
            }

            $secPwd = ConvertTo-SecureString $credPwd -AsPlainText -Force
            $encrypted = $secPwd | ConvertFrom-SecureString -Key $aesKey
            $encrypted | Set-Content -Path $outFile -Force

            # Update credentials.json registry with username
            if ($credUser) {
                $registryFile = Join-Path $credDir 'credentials.json'
                $registry = @{}
                if (Test-Path -LiteralPath $registryFile) {
                    $existing = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
                    foreach ($prop in $existing.PSObject.Properties) {
                        $registry[$prop.Name] = $prop.Value
                    }
                }
                $registry[$credName] = [pscustomobject]@{ UserName = $credUser }
                $sorted = [ordered]@{}
                $registry.GetEnumerator() | Sort-Object Key | ForEach-Object { $sorted[$_.Key] = $_.Value }
                $sorted | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $registryFile -Encoding utf8
                Reload-CredRegistry
            }

            # Refresh credential dropdowns
            $newCreds = @('') + @(Get-ChildItem -Path $credDir -Filter '*.cred' | ForEach-Object { $_.BaseName } | Sort-Object)
            foreach ($combo in @($controls['cmbSrcCredName'], $controls['cmbDestCredName'])) {
                $currentText = $combo.Text
                $combo.Items.Clear()
                foreach ($c in $newCreds) { $combo.Items.Add($c) | Out-Null }
                $combo.Text = $currentText
            }

            $statusMsg = "Created credential: $credName.cred"
            if ($credUser) { $statusMsg += " (user: $credUser)" }
            $controls['txtStatus'].Text = $statusMsg
            [System.Windows.MessageBox]::Show("Credential '$credName' created successfully.$(if ($credUser) { "`nUsername '$credUser' registered in credentials.json." })", 'Success', 'OK', 'Information')
        } catch {
            [System.Windows.MessageBox]::Show("Failed to create credential: $($_.Exception.Message)", 'Error', 'OK', 'Error')
        }
    }
})

$controls['btnSetCred'].Add_Click({
    # Dialog to update password for an existing credential — auto-fills name + username from registry
    [xml]$setCredXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Update Credential Password" Height="220" Width="450"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Label Content="Credential Name" Width="130"/>
            <ComboBox Name="cmbSetCredName" Width="260" IsEditable="True"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,8">
            <Label Content="Username" Width="130"/>
            <TextBox Name="txtSetCredUser" Width="260" IsReadOnly="True" Background="#F0F0F0"/>
        </StackPanel>
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,8">
            <Label Content="New Password" Width="130"/>
            <PasswordBox Name="pwdSetCredPassword" Width="260"/>
        </StackPanel>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnSetCredOk" Content="Update" Width="80" Padding="4" Margin="5" IsDefault="True"/>
            <Button Name="btnSetCredCancel" Content="Cancel" Width="80" Padding="4" Margin="5" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $setCredReader = [System.Xml.XmlNodeReader]::new($setCredXaml)
    $setCredDlg = [System.Windows.Markup.XamlReader]::Load($setCredReader)
    $setCredDlg.Owner = $window

    $cmbSetCred = $setCredDlg.FindName('cmbSetCredName')
    $txtSetUser = $setCredDlg.FindName('txtSetCredUser')

    # Populate dropdown with existing credentials
    foreach ($cred in ($availableCreds | Where-Object { $_ })) {
        $cmbSetCred.Items.Add($cred) | Out-Null
    }

    # Auto-fill username when credential selected
    $registry = $script:CredRegistry
    $cmbSetCred.Add_SelectionChanged({
        $credName = $cmbSetCred.Text
        if ($credName -and $registry -and $registry.ContainsKey($credName)) {
            $txtSetUser.Text = $registry[$credName]
        } else {
            $txtSetUser.Text = ''
        }
    }.GetNewClosure())
    $cmbSetCred.Add_LostFocus({
        $credName = $cmbSetCred.Text
        if ($credName -and $registry -and $registry.ContainsKey($credName)) {
            $txtSetUser.Text = $registry[$credName]
        }
    }.GetNewClosure())

    $setCredDlg.FindName('btnSetCredOk').Add_Click({
        param($s,$ev)
        $setCredDlg.DialogResult = $true
    }.GetNewClosure())

    $setCredDlg.FindName('btnSetCredCancel').Add_Click({
        param($s,$ev)
        $setCredDlg.DialogResult = $false
    }.GetNewClosure())

    if ($setCredDlg.ShowDialog()) {
        $credName = $cmbSetCred.Text.Trim()
        $newPwd   = $setCredDlg.FindName('pwdSetCredPassword').Password

        if (-not $credName) {
            [System.Windows.MessageBox]::Show('Credential name cannot be empty.', 'Error', 'OK', 'Error')
            return
        }
        if (-not $newPwd) {
            [System.Windows.MessageBox]::Show('Password cannot be empty.', 'Error', 'OK', 'Error')
            return
        }

        $credFile = Join-Path $workspaceRoot "credentials\$credName.cred"
        if (-not (Test-Path $credFile)) {
            [System.Windows.MessageBox]::Show("Credential file '$credName.cred' not found. Use 'New Credential' to create it first.", 'Error', 'OK', 'Error')
            return
        }

        try {
            $keyFile = Join-Path $workspaceRoot 'credentials\aes.key'
            $aesKey = Get-Content -Path $keyFile
            $secPwd = ConvertTo-SecureString $newPwd -AsPlainText -Force
            $encrypted = $secPwd | ConvertFrom-SecureString -Key $aesKey
            $encrypted | Set-Content -Path $credFile -Force

            $controls['txtStatus'].Text = "Updated password: $credName.cred ($(Get-Date -Format 'HH:mm:ss'))"
            [System.Windows.MessageBox]::Show("Password updated for '$credName'.", 'Success', 'OK', 'Information')
        } catch {
            [System.Windows.MessageBox]::Show("Failed to update password: $($_.Exception.Message)", 'Error', 'OK', 'Error')
        }
    }
})

$controls['btnAddPair'].Add_Click({
    $result = Show-PairEditor -Pair $null
    if ($result) {
        $script:Pairs.Add($result)
        $controls['txtStatus'].Text = "Added pair: $($result.Name)"
    }
})

$controls['btnEditPair'].Add_Click({
    $selected = $controls['dgPairs'].SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show("Select a pair to edit", "Info", 'OK', 'Information')
        return
    }
    $result = Show-PairEditor -Pair $selected
    if ($result) {
        $idx = $script:Pairs.IndexOf($selected)
        $script:Pairs[$idx] = $result
        $controls['txtStatus'].Text = "Updated pair: $($result.Name)"
    }
})

$controls['btnRemovePair'].Add_Click({
    $selected = $controls['dgPairs'].SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show("Select a pair to remove", "Info", 'OK', 'Information')
        return
    }
    $confirm = [System.Windows.MessageBox]::Show("Remove pair '$($selected.Name)'?", "Confirm", 'YesNo', 'Question')
    if ($confirm -eq 'Yes') {
        $script:Pairs.Remove($selected)
        $controls['txtStatus'].Text = "Removed pair: $($selected.Name)"
    }
})

$controls['btnDuplicatePair'].Add_Click({
    $selected = $controls['dgPairs'].SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show("Select a pair to duplicate", "Info", 'OK', 'Information')
        return
    }
    $clone = [pscustomobject]@{
        Name                          = "$($selected.Name)_copy"
        SourceCluster                 = $selected.SourceCluster
        SourceVserver                 = $selected.SourceVserver
        SourceCredentialName          = $selected.SourceCredentialName
        SourceCredentialUserName      = $selected.SourceCredentialUserName
        DestinationCluster            = $selected.DestinationCluster
        DestinationVserver            = $selected.DestinationVserver
        DestinationCredentialName     = $selected.DestinationCredentialName
        DestinationCredentialUserName = $selected.DestinationCredentialUserName
        DestinationCifsServerName     = $selected.DestinationCifsServerName
        DestinationOU                 = $selected.DestinationOU
        CreateDFSLink                 = $selected.CreateDFSLink
        ShareFilter                   = $selected.ShareFilter
    }
    $script:Pairs.Add($clone)
    $controls['txtStatus'].Text = "Duplicated pair: $($clone.Name)"
})

$controls['btnApplyJson'].Add_Click({
    try {
        $cfg = $controls['txtRawJson'].Text | ConvertFrom-Json
        Load-ConfigToForm -cfg $cfg
        $controls['txtStatus'].Text = "Applied JSON changes to form"
    } catch {
        [System.Windows.MessageBox]::Show("Invalid JSON: $($_.Exception.Message)", "Error", 'OK', 'Error')
    }
})

$controls['btnRefreshJson'].Add_Click({
    $config = Build-ConfigFromForm
    $controls['txtRawJson'].Text = $config | ConvertTo-Json -Depth 10
    $controls['txtStatus'].Text = "Refreshed JSON from form"
})

# --- Run Tab: Execution Engine ---
$script:RunspacePipeline = $null
$script:RunspacePool = $null
$script:RunTimer = $null
$script:RunStartTime = $null
$script:LastLogFile = $null

# Mode → Target relevance: only these modes use -Target
$script:TargetModes = @('TestCredentials', 'ResetCifsPassword', 'SetSPN')

# Disable Target dropdown for modes that don't use it
$controls['cmbRunMode'].Add_SelectionChanged({
    $mode = $controls['cmbRunMode'].Text
    $needsTarget = $mode -in $script:TargetModes
    $controls['cmbRunTarget'].IsEnabled = $needsTarget
    $controls['cmbRunTarget'].Opacity = if ($needsTarget) { 1.0 } else { 0.4 }
})
# Set initial state
$controls['cmbRunTarget'].IsEnabled = $controls['cmbRunMode'].Text -in $script:TargetModes
$controls['cmbRunTarget'].Opacity = if ($controls['cmbRunMode'].Text -in $script:TargetModes) { 1.0 } else { 0.4 }

function Append-Console {
    param([string]$Text)
    $controls['txtRunConsole'].Dispatcher.Invoke([Action]{
        $controls['txtRunConsole'].AppendText("$Text`r`n")
        $controls['txtRunConsole'].ScrollToEnd()
    }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Set-RunState {
    param([bool]$Running)
    $controls['btnRun'].IsEnabled = -not $Running
    $controls['btnRunStop'].IsEnabled = $Running
    $controls['cmbRunMode'].IsEnabled = -not $Running
    # Only re-enable Target if mode uses it
    if (-not $Running) {
        $needsTarget = $controls['cmbRunMode'].Text -in $script:TargetModes
        $controls['cmbRunTarget'].IsEnabled = $needsTarget
        $controls['cmbRunTarget'].Opacity = if ($needsTarget) { 1.0 } else { 0.4 }
    } else {
        $controls['cmbRunTarget'].IsEnabled = $false
    }
    if ($Running) {
        $controls['txtRunStatus'].Text = 'Running...'
        $controls['txtRunStatus'].Foreground = [System.Windows.Media.Brushes]::Orange
    } else {
        $controls['txtRunStatus'].Foreground = [System.Windows.Media.Brushes]::Black
    }
}

$controls['btnRunClear'].Add_Click({
    $controls['txtRunConsole'].Clear()
    $controls['txtRunElapsed'].Text = ''
    $controls['txtRunStatus'].Text = 'Idle'
    $controls['txtRunStatus'].Foreground = [System.Windows.Media.Brushes]::Black
})

$controls['btnOpenLog'].Add_Click({
    $logDir = Join-Path $workspaceRoot 'scripts\share-migration\logs'
    if (Test-Path $logDir) {
        $latest = Get-ChildItem -Path $logDir -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            Start-Process notepad.exe -ArgumentList $latest.FullName
        } else {
            [System.Windows.MessageBox]::Show("No log files found in $logDir", 'Info', 'OK', 'Information')
        }
    } else {
        [System.Windows.MessageBox]::Show("Log directory not found: $logDir", 'Info', 'OK', 'Information')
    }
})

$controls['btnOpenExports'].Add_Click({
    $exportDir = Join-Path $workspaceRoot 'scripts\share-migration\exports'
    if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList $exportDir
})

$controls['btnRun'].Add_Click({
    $mode = $controls['cmbRunMode'].Text
    $target = $controls['cmbRunTarget'].Text
    
    if (-not $mode) {
        [System.Windows.MessageBox]::Show('Select a mode to run.', 'Info', 'OK', 'Information')
        return
    }
    
    # Confirm destructive modes
    if ($mode -in @('DomainMigration', 'Rollback', 'ResetCifsPassword')) {
        $confirm = [System.Windows.MessageBox]::Show(
            "Mode '$mode' makes changes to CIFS/domain configuration.`n`nAre you sure you want to proceed?",
            'Confirm Destructive Operation', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
    }
    
    # Save config before running (ensures latest form values are used)
    try {
        Save-Config -TargetPath $script:ConfigPath
        Append-Console "[GUI] Config saved to $($script:ConfigPath)"
    } catch {
        [System.Windows.MessageBox]::Show("Failed to save config before run: $($_.Exception.Message)", 'Error', 'OK', 'Error')
        return
    }
    
    # Build command
    $scriptPath = Join-Path $workspaceRoot 'scripts\share-migration\Invoke-ShareMigration.ps1'
    $args = "-Mode $mode"
    if ($mode -eq 'Preflight') { $args += ' -ApprovePreflight' }
    if ($mode -in @('TestCredentials', 'ResetCifsPassword', 'SetSPN')) { $args += " -Target $target" }
    
    Append-Console ''
    Append-Console "═══════════════════════════════════════════════════════════"
    Append-Console "[GUI] Starting: $mode $(if ($mode -in @('TestCredentials','ResetCifsPassword','SetSPN')) { "(-Target $target)" })"
    Append-Console "[GUI] Script: $scriptPath $args"
    Append-Console "═══════════════════════════════════════════════════════════"
    
    Set-RunState -Running $true
    $script:RunStartTime = [DateTime]::Now
    
    # Timer for elapsed time display
    $script:RunTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:RunTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:RunTimer.Add_Tick({
        if ($script:RunStartTime) {
            $elapsed = [DateTime]::Now - $script:RunStartTime
            $controls['txtRunElapsed'].Text = 'Elapsed: {0:mm\:ss}' -f $elapsed
        }
    })
    $script:RunTimer.Start()
    
    # Create runspace with synchronized hashtable for thread-safe output
    $syncHash = [hashtable]::Synchronized(@{
        Console   = $controls['txtRunConsole']
        Status    = $controls['txtRunStatus']
        Elapsed   = $controls['txtRunElapsed']
        BtnRun    = $controls['btnRun']
        BtnStop   = $controls['btnRunStop']
        CmbMode   = $controls['cmbRunMode']
        CmbTarget = $controls['cmbRunTarget']
        Timer     = $script:RunTimer
        Done      = $false
        Error     = $null
    })
    
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('syncHash', $syncHash)
    $runspace.SessionStateProxy.SetVariable('scriptPath', $scriptPath)
    $runspace.SessionStateProxy.SetVariable('argString', $args)
    $runspace.SessionStateProxy.SetVariable('workspaceRoot', $workspaceRoot)
    
    $psCmd = [powershell]::Create().AddScript({
        try {
            # Redirect all streams
            $outputLines = [System.Collections.Generic.List[string]]::new()
            
            # Load profile so cluster functions are available
            $profilePath = Join-Path $workspaceRoot 'profile1.ps1'
            if (Test-Path $profilePath) {
                Set-Location $workspaceRoot
                . $profilePath
            }
            
            $expression = "& '$scriptPath' $argString *>&1"
            $results = Invoke-Expression $expression
            
            foreach ($line in $results) {
                $text = "$line"
                $syncHash.Console.Dispatcher.Invoke([Action]{
                    $syncHash.Console.AppendText("$text`r`n")
                    $syncHash.Console.ScrollToEnd()
                }, [System.Windows.Threading.DispatcherPriority]::Background)
            }
        }
        catch {
            $syncHash.Error = $_.Exception.Message
            $syncHash.Console.Dispatcher.Invoke([Action]{
                $syncHash.Console.AppendText("`r`n[ERROR] $($syncHash.Error)`r`n")
                if ($_.ScriptStackTrace) {
                    $syncHash.Console.AppendText("[STACK] $($_.ScriptStackTrace)`r`n")
                }
                $syncHash.Console.ScrollToEnd()
            }, [System.Windows.Threading.DispatcherPriority]::Background)
        }
        finally {
            $syncHash.Done = $true
            $syncHash.Console.Dispatcher.Invoke([Action]{
                $syncHash.BtnRun.IsEnabled = $true
                $syncHash.BtnStop.IsEnabled = $false
                $syncHash.CmbMode.IsEnabled = $true
                $syncHash.CmbTarget.IsEnabled = $true
                $syncHash.Timer.Stop()
                
                if ($syncHash.Error) {
                    $syncHash.Status.Text = 'FAILED'
                    $syncHash.Status.Foreground = [System.Windows.Media.Brushes]::Red
                } else {
                    $syncHash.Status.Text = 'Completed'
                    $syncHash.Status.Foreground = [System.Windows.Media.Brushes]::Green
                }
            }, [System.Windows.Threading.DispatcherPriority]::Background)
        }
    })
    
    $psCmd.Runspace = $runspace
    $script:RunspacePipeline = $psCmd
    $script:RunspacePool = $runspace
    $psCmd.BeginInvoke() | Out-Null
})

$controls['btnRunStop'].Add_Click({
    if ($script:RunspacePipeline) {
        try {
            $script:RunspacePipeline.Stop()
            Append-Console "`r`n[GUI] Operation stopped by user"
        } catch {}
        Set-RunState -Running $false
        $controls['txtRunStatus'].Text = 'Stopped'
        $controls['txtRunStatus'].Foreground = [System.Windows.Media.Brushes]::DarkOrange
        if ($script:RunTimer) { $script:RunTimer.Stop() }
    }
})

# Cleanup runspace on window close
$window.Add_Closed({
    if ($script:RunspacePipeline) {
        try { $script:RunspacePipeline.Stop() } catch {}
        try { $script:RunspacePipeline.Dispose() } catch {}
    }
    if ($script:RunspacePool) {
        try { $script:RunspacePool.Close() } catch {}
        try { $script:RunspacePool.Dispose() } catch {}
    }
})

# --- Load initial config ---
if (Test-Path -LiteralPath $Path) {
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Load-ConfigToForm -cfg $cfg
    } catch {
        $controls['txtStatus'].Text = "Failed to load $Path — $($_.Exception.Message)"
    }
} else {
    $controls['txtStatus'].Text = "No config file found at $Path — start fresh or Load"
}

# --- Show window ---
$window.ShowDialog() | Out-Null
