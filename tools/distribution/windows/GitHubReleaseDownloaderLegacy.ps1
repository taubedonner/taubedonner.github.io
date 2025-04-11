Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$global:CachedConfig = $null
$configPath = "$env:USERPROFILE\.gh_release_downloader.json"

function Write-DebugLog {
    param (
        [string]$Step,
        [string]$Message,
        [object]$Data,
        [switch]$IsError,
        [switch]$Blank
    )
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    $prefix = "$timestamp | $($Step.PadRight(25)) | "
    if ($IsError) {
        Write-Host "$prefix[ERROR] $Message" -ForegroundColor Red
        if ($Data) { Write-Host "$($prefix)  └─ $($Data | Out-String)".Trim() -ForegroundColor DarkRed }
    }
    else {
        Write-Host "$prefix[INFO] $Message" -ForegroundColor Cyan
        if ($Data) { Write-Host "$($prefix)  └─ $($Data | ConvertTo-Json -Compress)" -ForegroundColor DarkCyan }
    }
    if ($Blank) { Write-Host }
}

function Load-Config {
    if ($global:CachedConfig) { return $global:CachedConfig }
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath | ConvertFrom-Json
            if ($config.RepoPath -match '^[\w-]+/[\w-]+$') {
                $global:CachedConfig = $config
                Write-DebugLog -Step "LOAD_CONFIG" -Message "Настройки загружены" -Data @{RepoPath = $config.RepoPath }
                return $config
            }
        }
        catch {
            Write-DebugLog -Step "LOAD_CONFIG" -Message "Ошибка десериализации" -Data $_ -IsError
        }
    }
    Write-DebugLog -Step "LOAD_CONFIG" -Message "Конфиг не найден или поврежден" -IsError
    return $null
}

function Save-Config {
    param (
        [string]$RepoPath,
        [string]$AccessToken = ""
    )
    @{
        RepoPath    = $RepoPath
        AccessToken = $AccessToken
    } | ConvertTo-Json | Set-Content $configPath -Force
    $global:CachedConfig = $null
    Write-DebugLog -Step "SAVE_CONFIG" -Message "Настройки сохранены" -Data @{RepoPath = $RepoPath } -Blank
}

function Invoke-GitHubApi {
    param (
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )

    try {
        $safeHeaders = @{}
        foreach ($key in $Headers.Keys) {
            $safeHeaders[$key] = if ($key -eq 'Authorization') { 'token ****' } else { $Headers[$key] }
        }
        Write-DebugLog -Step "API_REQUEST" -Message "$Method $Uri" -Data @{
            Headers = ($safeHeaders.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        }
        $response = Invoke-WebRequest -Uri $Uri -Method $Method -Headers $Headers -Body $Body -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json
        Write-DebugLog -Step "API_RESPONSE" -Message "Успешный запрос" -Data @{StatusCode = $response.StatusCode } -Blank
        return $content
    }
    catch {
        $errorData = @{
            StatusCode = $_.Exception.Response.StatusCode.value__
            Message    = $_.Exception.Message
            Uri        = $Uri
        }
        Write-DebugLog -Step "API_ERROR" -Message "Ошибка запроса" -Data $errorData -IsError -Blank
        throw $_
    }
}

function Check-ChangeLogExists {
    param (
        [string]$Owner,
        [string]$Repo,
        [string]$AccessToken
    )
    $headers = @{}
    if ($AccessToken) {
        $headers['Authorization'] = "token $AccessToken"
    }
    try {
        $contentsUrl = "https://api.github.com/repos/$Owner/$Repo/contents/"
        $contents = Invoke-GitHubApi -Uri $contentsUrl -Headers $headers
        return $contents | Where-Object { 
            $_.name -eq 'CHANGELOG.md' -and $_.type -eq 'file'
        } | Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Show-ContentWindow {
    param (
        [string]$Title,
        [string]$Content
    )
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(800, 600)
    $form.StartPosition = "CenterParent"
    
    $textBox = New-Object System.Windows.Forms.RichTextBox
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.ReadOnly = $true
    $textBox.Text = $Content
    $textBox.BackColor = [System.Drawing.SystemColors]::Window
    
    $form.Controls.Add($textBox)
    $form.ShowDialog()
}

function Load-Releases {
    $config = Load-Config
    if (-not $config) { return }
    
    $repoParts = $config.RepoPath -split '/'
    $owner = $repoParts[0]
    $repo = $repoParts[1]
    $token = $config.AccessToken
    
    $headers = @{}
    if ($token) {
        $headers['Authorization'] = "token $token"
    }
    
    try {
        $repoInfo = Invoke-GitHubApi -Uri "https://api.github.com/repos/$owner/$repo" -Headers $headers
        $isPrivate = $repoInfo.private
        
        if ($isPrivate -and -not $token) {
            throw "Для приватного репозитория требуется токен"
        }
        
        $url = "https://api.github.com/repos/$owner/$repo/releases"
        $response = Invoke-GitHubApi -Uri $url -Headers $headers
        
        $releaseGrid.Rows.Clear()
        foreach ($release in $response) {
            $type = if ($release.prerelease) { "Пререлиз" } else { "Релиз" }
            $published = [datetime]$release.published_at
            $author = $release.author.login
            $releaseGrid.Rows.Add(
                $release.name,
                $release.tag_name,
                $published.ToShortDateString(),
                $type,
                $author,
                $release.body
            ) | Out-Null
        }
        
        $changelog = Check-ChangeLogExists -Owner $owner -Repo $repo -AccessToken $token
        $changelogButton.Visible = [bool]$changelog
        $releaseNotesButton.Visible = $false
        
        $releaseHeader.Visible = $true
        $assetHeader.Visible = $false
        $releaseGrid.Visible = $true
        $assetGrid.Visible = $false
        $downloadButton.Visible = $false
        $statusLabel.Text = ""
        
        if ($releaseGrid.RowCount -gt 0) {
            $releaseGrid.Rows[0].Selected = $true
            $selectedTag = $releaseGrid.Rows[0].Cells[1].Value
            Load-Assets -Tag $selectedTag
            $releaseNotesButton.Visible = $true
        }
    }
    catch {
        $statusLabel.Text = "Ошибка загрузки релизов: $_"
        $assetGrid.Visible = $false
        $assetHeader.Visible = $false
        $releaseGrid.Visible = $false
        $releaseHeader.Visible = $false
        $changelogButton.Visible = $false
        $releaseNotesButton.Visible = $false
    }
}

function Load-Assets {
    param (
        [string]$Tag
    )
    $config = Load-Config
    if (-not $config) { return }
    
    $repoParts = $config.RepoPath -split '/'
    $owner = $repoParts[0]
    $repo = $repoParts[1]
    $token = $config.AccessToken
    
    $headers = @{}
    if ($token) {
        $headers['Authorization'] = "token $token"
    }
    
    try {
        Write-DebugLog -Step "LOAD_ASSETS" -Message "Загрузка ассетов для тега $Tag" -Blank
        $url = "https://api.github.com/repos/$owner/$repo/releases/tags/$Tag"
        $release = Invoke-GitHubApi -Uri $url -Headers $headers
        
        $assetGrid.Rows.Clear()
        foreach ($asset in $release.assets) {
            $sizeMB = [math]::Round($asset.size / 1MB, 2)
            $assetGrid.Rows.Add($asset.name, "$sizeMB MB", $asset.download_count, $asset.content_type) | Out-Null
        }
        
        $assetHeader.Visible = $true
        $assetGrid.Visible = $true
        $downloadButton.Visible = $true
    }
    catch {
        Write-DebugLog -Step "LOAD_ASSETS" -Message "Ошибка загрузки ассетов" -Data $_ -IsError -Blank
        [System.Windows.Forms.MessageBox]::Show("Ошибка загрузки ассетов: $_", "Ошибка")
        $assetHeader.Visible = $false
        $assetGrid.Visible = $false
    }
}

function Show-SuccessDialog {
    param (
        [string]$FilePath
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Успех"
    $dialog.Size = New-Object System.Drawing.Size(200, 135)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Файл успешно скачан"
    $label.Location = New-Object System.Drawing.Point(10, 20)
    $label.AutoSize = $true
    
    $showButton = New-Object System.Windows.Forms.Button
    $showButton.Text = "Показать"
    $showButton.Location = New-Object System.Drawing.Point(10, 60)
    $showButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = New-Object System.Drawing.Point(100, 60)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    
    $dialog.Controls.AddRange(@($label, $showButton, $okButton))
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $okButton
    
    $result = $dialog.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process "explorer.exe" -ArgumentList "/select,`"$FilePath`""
    }
}

# Основная форма
$form = New-Object System.Windows.Forms.Form
$form.Text = "GitHub Release Downloader"
$form.Size = New-Object System.Drawing.Size(900, 700)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false

# Поля ввода
$repoLabel = New-Object System.Windows.Forms.Label
$repoLabel.Text = "Репозиторий (owner/repo):"
$repoLabel.Location = New-Object System.Drawing.Point(20, 20)
$repoLabel.AutoSize = $true

$repoTextBox = New-Object System.Windows.Forms.TextBox
$repoTextBox.Location = New-Object System.Drawing.Point(180, 20)
$repoTextBox.Width = 300

$tokenLabel = New-Object System.Windows.Forms.Label
$tokenLabel.Text = "Access Token:"
$tokenLabel.Location = New-Object System.Drawing.Point(20, 60)
$tokenLabel.AutoSize = $true

$tokenTextBox = New-Object System.Windows.Forms.TextBox
$tokenTextBox.Location = New-Object System.Drawing.Point(180, 60)
$tokenTextBox.Width = 300
$tokenTextBox.PasswordChar = '*'

$saveConfigButton = New-Object System.Windows.Forms.Button
$saveConfigButton.Text = "Применить настройки"
$saveConfigButton.Location = New-Object System.Drawing.Point(500, 15)
$saveConfigButton.Size = New-Object System.Drawing.Size(150, 30)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 100)
$statusLabel.AutoSize = $true
$statusLabel.ForeColor = [System.Drawing.Color]::Red

# Заголовки таблиц
$releaseHeader = New-Object System.Windows.Forms.Label
$releaseHeader.Text = "Релизы репозитория"
$releaseHeader.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$releaseHeader.Location = New-Object System.Drawing.Point(20, 115)
$releaseHeader.AutoSize = $true
$releaseHeader.Visible = $false

$assetHeader = New-Object System.Windows.Forms.Label
$assetHeader.Text = "Файлы релиза"
$assetHeader.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$assetHeader.Location = New-Object System.Drawing.Point(20, 360)
$assetHeader.AutoSize = $true
$assetHeader.Visible = $false

# Таблица релизов
$releaseGrid = New-Object System.Windows.Forms.DataGridView
$releaseGrid.Location = New-Object System.Drawing.Point(20, 140)
$releaseGrid.Size = New-Object System.Drawing.Size(840, 200)
$releaseGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$releaseGrid.Visible = $false
$releaseGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$releaseGrid.MultiSelect = $false
$releaseGrid.ColumnCount = 6
$releaseGrid.Columns[0].Name = "Версия"
$releaseGrid.Columns[1].Name = "Тег"
$releaseGrid.Columns[2].Name = "Дата"
$releaseGrid.Columns[3].Name = "Тип"
$releaseGrid.Columns[4].Name = "Автор"
$releaseGrid.Columns[5].Name = "ReleaseNotes"
$releaseGrid.Columns[5].Visible = $false
$releaseGrid.AllowUserToAddRows = $false
$releaseGrid.ReadOnly = $true

# Таблица ассетов
$assetGrid = New-Object System.Windows.Forms.DataGridView
$assetGrid.Location = New-Object System.Drawing.Point(20, 385)
$assetGrid.Size = New-Object System.Drawing.Size(840, 200)
$assetGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$assetGrid.Visible = $false
$assetGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$assetGrid.MultiSelect = $false
$assetGrid.ColumnCount = 4
$assetGrid.Columns[0].Name = "Файл"
$assetGrid.Columns[1].Name = "Размер"
$assetGrid.Columns[2].Name = "Загрузок"
$assetGrid.Columns[3].Name = "Тип"
$assetGrid.AllowUserToAddRows = $false
$assetGrid.ReadOnly = $true

# Кнопки управления
$downloadButton = New-Object System.Windows.Forms.Button
$downloadButton.Text = "Скачать"
$downloadButton.Location = New-Object System.Drawing.Point(760, 615)
$downloadButton.Size = New-Object System.Drawing.Size(100, 30)
$downloadButton.Visible = $false

# Кнопка CHANGELOG
$changelogButton = New-Object System.Windows.Forms.Button
$changelogButton.Text = "Показать CHANGELOG"
$changelogButton.Location = New-Object System.Drawing.Point(20, 615)
$changelogButton.Size = New-Object System.Drawing.Size(150, 30)
$changelogButton.Visible = $false

# Кнопка примечаний к релизу
$releaseNotesButton = New-Object System.Windows.Forms.Button
$releaseNotesButton.Text = "Показать примечания"
$releaseNotesButton.Location = New-Object System.Drawing.Point(200, 615)
$releaseNotesButton.Size = New-Object System.Drawing.Size(150, 30)
$releaseNotesButton.Visible = $false

# Обработчики
$saveConfigButton.Add_Click({
        $repoPath = $repoTextBox.Text
        $accessToken = $tokenTextBox.Text
    
        if ($repoPath -match '^[\w-]+/[\w-]+$') {
            Save-Config -RepoPath $repoPath -AccessToken $accessToken
            Load-Releases
        }
        else {
            Write-DebugLog -Step "SAVE_CONFIG" -Message "Неверный формат репозитория" -IsError
            $statusLabel.Text = "Неверный формат репозитория"
        }
    })

$releaseGrid.Add_Click({
        if ($releaseGrid.SelectedRows.Count -eq 0) { return }
        $selectedTag = $releaseGrid.SelectedRows[0].Cells[1].Value
        Load-Assets -Tag $selectedTag
        $releaseNotesButton.Visible = $true
    })

$releaseNotesButton.Add_Click({
        if (-not $releaseGrid.SelectedRows) { return }
        $selectedRow = $releaseGrid.SelectedRows[0]
        $releaseNotes = $selectedRow.Cells["ReleaseNotes"].Value
    
        if ([string]::IsNullOrEmpty($releaseNotes)) {
            [System.Windows.Forms.MessageBox]::Show("Примечания к релизу отсутствуют", "Информация")
            return
        }
    
        Show-ContentWindow -Title "Примечания к релизу: $($selectedRow.Cells["Версия"].Value)" -Content $releaseNotes
    })

$changelogButton.Add_Click({
        $config = Load-Config
        if (-not $config) { return }
    
        $repoParts = $config.RepoPath -split '/'
        $owner = $repoParts[0]
        $repo = $repoParts[1]
        $token = $config.AccessToken
    
        $changelog = Check-ChangeLogExists -Owner $owner -Repo $repo -AccessToken $token
        if ($changelog) {
            try {
                $response = Invoke-WebRequest -Uri $changelog.download_url
                Show-ContentWindow -Title "CHANGELOG.md" -Content $response.Content
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show("Ошибка загрузки CHANGELOG: $_", "Ошибка")
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("CHANGELOG.md не найден", "Информация")
        }
    })

$assetGrid.Add_DoubleClick({
        if ($assetGrid.SelectedRows.Count -eq 0 -or $assetGrid.SelectedRows[0].IsNewRow) { return }
        $downloadButton.PerformClick()
    })

$downloadButton.Add_Click({
        $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
        $selectedAsset = $assetGrid.SelectedRows[0].Cells[0].Value
        $saveFileDialog.FileName = $selectedAsset
    
        if ($saveFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $config = Load-Config
            if (-not $config) { return }
        
            $repoParts = $config.RepoPath -split '/'
            $owner = $repoParts[0]
            $repo = $repoParts[1]
            $token = $config.AccessToken
            $assetName = $assetGrid.SelectedRows[0].Cells[0].Value
            $releaseTag = $releaseGrid.SelectedRows[0].Cells[1].Value

            $headers = @{}
            if ($token) {
                $headers['Authorization'] = "token $token"
            }
        
            try {
                $url = "https://api.github.com/repos/$owner/$repo/releases/tags/$releaseTag"
                $release = Invoke-GitHubApi -Uri $url -Headers $headers
                $asset = $release.assets | Where-Object { $_.name -eq $assetName }
            
                if (-not $asset) {
                    throw "Ассет '$assetName' не найден в релизе '$releaseTag'"
                }
            
                $assetUrl = "https://api.github.com/repos/$owner/$repo/releases/assets/$($asset.id)"
                $headers['Accept'] = 'application/octet-stream'
                Write-DebugLog -Step "DOWNLOAD" -Message "Скачивание ассета" -Data @{
                    AssetName = $assetName
                    AssetUrl = $assetUrl
                }

                Invoke-WebRequest -Uri $assetUrl -Headers $headers -OutFile $saveFileDialog.FileName

                Write-DebugLog -Step "DOWNLOAD" -Message "Успешно скачано" -Data @{FilePath=$saveFileDialog.FileName}
                Show-SuccessDialog -FilePath $saveFileDialog.FileName
            }
            catch {
                Write-DebugLog -Step "DOWNLOAD" -Message "Ошибка скачивания" -Data $_ -IsError
                [System.Windows.Forms.MessageBox]::Show("Ошибка скачивания: $_", "Ошибка")
            }
        }
    })

# Инициализация
$config = Load-Config
if ($config) {
    $repoTextBox.Text = $config.RepoPath
    $tokenTextBox.Text = $config.AccessToken
    Load-Releases
}

# Добавление элементов
$form.Controls.AddRange(@(
        $repoLabel,
        $repoTextBox,
        $tokenLabel,
        $tokenTextBox,
        $saveConfigButton,
        $statusLabel,
        $releaseGrid,
        $assetGrid,
        $downloadButton,
        $releaseHeader,
        $assetHeader,
        $changelogButton,
        $releaseNotesButton
    ))

# Запуск
[System.Windows.Forms.Application]::Run($form)