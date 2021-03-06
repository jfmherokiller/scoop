<#
TODO
 - add a github release autoupdate type
 - tests (single arch, without hashes etc.)
 - clean up
#>

function substitute([String] $str, [Hashtable] $params) {
    $params.GetEnumerator() | % {
        $str = $str.Replace($_.Name, $_.Value)
    }

    return $str
}

function check_url([String] $url) {
    if ($url.Contains("github.com") -or $url.Contains("chocolatey.org")) {
        # github does not allow HEAD requests
        warn "Unable to check github/chocolatey url (assuming it is ok)"
        return $true
    }

    $response = Invoke-WebRequest -Uri $url -Method HEAD
    if ($response.StatusCode.Equals(200)) { # redirects might be ok
        return $true
    }

    return $false
}

function find_hash_in_rdf([String] $url, [String] $filename)
{
    Write-Host -f DarkYellow "RDF URL: $url"
    Write-Host -f DarkYellow "File: $filename"

    # Download and parse RDF XML file
    [xml]$data = (new-object net.webclient).downloadstring($url)

    # Find file content
    $digest = $data.RDF.Content | ? { [String]$_.about -eq $filename }

    return $digest.sha256
}

function get_hash_for_app([String] $app, $config, [String] $version, [String] $url, [Hashtable] $substitutions)
{
    $hash = $null

    <#
    TODO implement more hashing types
    `extract` Should be able to extract from origin page source (checkver)
    `rdf` Find hash from a RDF Xml file
    `download` Last resort, download the real file and hash it
    #>
    $hashmode = $config.mode
    $basename = fname($url)
    if ($hashmode -eq "extract") {
        $hashfile_url = substitute $config.url @{'$url' = $url}
        $hashfile_url = substitute $hashfile_url $substitutions
        $hashfile = (new-object net.webclient).downloadstring($hashfile_url)

        $regex = $config.find
        if ($regex -eq $null) {
            $regex = "([a-z0-9]+)"
        }
        $regex = substitute $regex @{'$basename' = [regex]::Escape($basename)}

        if ($hashfile -match $regex) {
            $hash = $matches[1]

            if ($config.type -and !($config.type -eq "sha256")) {
                $hash = $config.type + ":$hash"
            }

            return $hash
        }
    } elseif ($hashmode -eq "rdf") {
        return find_hash_in_rdf $config.url $basename
    } else {
        Write-Host "Download files to compute hashes!" -f DarkYellow
        dl_with_cache $app $version $url $null $null $true
        $file = fullpath (cache_path $app $version $url)
        return compute_hash $file "sha256"
    }
}

function update_manifest_with_new_version($json, [String] $version, [String] $url, [String] $hash, $architecture = $null)
{
    $json.version = $version

    if ($architecture -eq $null) {
        if ($json.url -is [System.Array]) {
            $json.url[0] = $url
            $json.hash[0] = $hash
        } else {
            $json.url = $url
            $json.hash = $hash
        }
    } else {
        # If there are multiple urls we replace the first one
        if ($json.architecture.$architecture.url -is [System.Array]) {
            $json.architecture.$architecture.url[0] = $url
            $json.architecture.$architecture.hash[0] = $hash
        } else {
            $json.architecture.$architecture.url = $url
            $json.architecture.$architecture.hash = $hash
        }
    }
}

function update_manifest_prop([String] $prop, $json, [Hashtable] $substitutions)
{
    # first try the global property
    if ($json.$prop -and $json.autoupdate.$prop) {
        $json.$prop = substitute $json.autoupdate.$prop $substitutions
    }

    # check if there are architecture specific variants
    if ($json.architecture) {
        $json.architecture | Get-Member -MemberType NoteProperty | % {
            $architecture = $_.Name

            if ($json.architecture.$architecture.$prop) {
                $json.architecture.$architecture.$prop = substitute (arch_specific $prop $json.autoupdate $architecture) $substitutions
            }
        }
    }
}

function get_version_substitutions([String] $version, [Hashtable] $matches)
{
    $firstPart = $version.Split('-') | Select-Object -first 1
    $lastPart = $version.Split('-') | Select-Object -last 1
    $versionVariables = @{
        '$version' = $version;
        '$underscoreVersion' = ($version -replace "\.", "_");
        '$cleanVersion' = ($version -replace "\.", "");
        '$majorVersion' = $firstPart.Split('.') | Select-Object -first 1;
        '$minorVersion' = $firstPart.Split('.') | Select-Object -skip 1 -first 1;
        '$patchVersion' = $firstPart.Split('.') | Select-Object -skip 2 -first 1;
        '$buildVersion' = $firstPart.Split('.') | Select-Object -skip 3 -first 1;
        '$preReleaseVersion' = $lastPart;
    }
    $matches.GetEnumerator() | Select -SkipLast 1 | % {
        $versionVariables.Add('$match' + (Get-Culture).TextInfo.ToTitleCase($_.Name), $_.Value)
    }
    return $versionVariables
}

function autoupdate([String] $app, $dir, $json, [String] $version, [Hashtable] $matches)
{
    Write-Host -f DarkCyan "Autoupdating $app"
    $has_changes = $false
    $has_errors = $false
    [Bool]$valid = $true
    $substitutions = get_version_substitutions $version $matches

    if ($json.url) {
        # create new url
        $url = substitute $json.autoupdate.url $substitutions

        # check url
        if (!(check_url $url)) {
            $valid = $false
            Write-Host -f DarkRed "URL $url is not valid"
        }

        # create hash
        $hash = get_hash_for_app $app $json.autoupdate.hash $version $url $substitutions
        if ($hash -eq $null) {
            $valid = $false
            Write-Host -f DarkRed "Could not find hash!"
        }

        # write changes to the json object
        if ($valid) {
            $has_changes = $true
            update_manifest_with_new_version $json $version $url $hash
        } else {
            $has_errors = $true
            Write-Host -f DarkRed "Could not update $app"
        }
    } else {
        $json.architecture | Get-Member -MemberType NoteProperty | % {
            $valid = $true
            $architecture = $_.Name

            # create new url
            $url = substitute (arch_specific "url" $json.autoupdate $architecture) $substitutions

            # check url
            if (!(check_url $url)) {
                $valid = $false
                Write-Host -f DarkRed "URL $url is not valid"
            }

            # create hash
            $hash = get_hash_for_app $app (arch_specific "hash" $json.autoupdate $architecture) $version $url $substitutions
            if ($hash -eq $null) {
                $valid = $false
                Write-Host -f DarkRed "Could not find hash!"
            }

            # write changes to the json object
            if ($valid) {
                $has_changes = $true
                update_manifest_with_new_version $json $version $url $hash $architecture
            } else {
                $has_errors = $true
                Write-Host -f DarkRed "Could not update $app $architecture"
            }
        }
    }

    # update properties
    update_manifest_prop "extract_dir" $json $substitutions

    if ($has_changes -and !$has_errors) {
        # write file
        Write-Host -f DarkGreen "Writing updated $app manifest"

        $path = "$dir\$app.json"

        $file_content = $json | ConvertToPrettyJson
        [System.IO.File]::WriteAllLines($path, $file_content)

        # notes
        if ($json.autoupdate.note) {
            Write-Host ""
            Write-Host -f DarkYellow $json.autoupdate.note
        }
    } else {
        Write-Host -f DarkGray "No updates for $app"
    }
}
