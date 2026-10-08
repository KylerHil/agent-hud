#!/usr/bin/env python3
"""Package a local macOS VSIX with the broker; no npm install or runtime dependencies."""
import json
import pathlib
import platform
import sys
import zipfile
import xml.sax.saxutils as xml

root = pathlib.Path(__file__).resolve().parents[1]
extension = root / 'extensions/agenthud-vscode'
binary = root / '.build/release/agenthud-broker'
if not binary.is_file():
    sys.exit('Run swift build -c release first.')
package = json.loads((extension / 'package.json').read_text())
target = 'darwin-arm64' if platform.machine() == 'arm64' else 'darwin-x64'
output = root / 'build/agenthud-workspace-bridge.vsix'
output.parent.mkdir(exist_ok=True)
manifest = f'''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
 <Metadata><Identity Language="en-US" Id="{package['name']}" Version="{package['version']}" Publisher="{package['publisher']}" TargetPlatform="{target}"/>
 <DisplayName>{xml.escape(package['displayName'])}</DisplayName><Description xml:space="preserve">{xml.escape(package['description'])}</Description>
 <Tags>agent,workspace,coordinator</Tags><Categories>Other</Categories>
 <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.95.0"/><Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/></Properties>
 </Metadata><Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation><Dependencies/>
 <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>'''
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('extension.vsixmanifest', manifest)
    archive.writestr('[Content_Types].xml', '''<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="md" ContentType="text/markdown"/><Default Extension="vsixmanifest" ContentType="text/xml"/><Default Extension="" ContentType="application/octet-stream"/></Types>''')
    for filename in ['package.json', 'extension.js', 'client.js', 'README.md']:
        archive.write(extension / filename, 'extension/' + filename)
    archive.write(binary, 'extension/bin/agenthud-broker')
print(output)
