REM This am_depends file handles python and node.js dependencies.
REM Set a few vars. Tailor as needed.
REM
set SPLUNK_HOME=%ProgramFiles%\Splunk
set PYTHON_SITEPACKAGES=%ProgramFiles%\python27\lib\site-packages
set SPLUNK_SITEPACKAGES=%ProgramFiles%\splunk\Python-2.7\lib\site-packages

REM Install a few packages. They drag in dependents.
REM
set PATH=%PATH%;%ProgramFiles%\Python27\;%ProgramFiles%\Python27\Scripts
pip install msrestazure -t "%SPLUNK_HOME%\etc\apps\TA-Azure_Monitor\bin"
pip install splunk-sdk -t "%SPLUNK_HOME%\etc\apps\TA-Azure_Monitor\bin"
pip install splunk-sdk -t "%SPLUNK_HOME%\etc\apps\TA-Azure_Monitor\bin\app"
pip install futures -t "%SPLUNK_HOME%\etc\apps\TA-Azure_Monitor\bin"

REM Restore node_modules packages.
REM
set PATH=%PATH%;%ProgramFiles%\nodejs\;C:\Users\jasothAdmin\AppData\Roaming\npm
cd "%SPLUNK_HOME%\etc\apps\TA-Azure_Monitor\bin\app"
npm install
