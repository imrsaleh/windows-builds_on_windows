streamlink/windows-builds
====

### Build requirements

- [git](https://git-scm.com/)
- [Python 3.13.7](https://www.python.org/) and the most recent version of [pip](https://pip.pypa.io/en/stable/)
  - [virtualenv](https://pypi.org/project/virtualenv/)
  - [pynsist](https://pypi.org/project/pynsist/) `==2.8`
  - [distlib](https://pypi.org/project/distlib/) `==0.3.6`
  - [freezegun](https://pypi.org/project/freezegun/)
- [NSIS](https://nsis.sourceforge.io/Main_Page)
- [jq](https://stedolan.github.io/jq/)
- [gawk](https://www.gnu.org/software/gawk/)
- [Imagemagick](https://imagemagick.org/index.php)
- [Inkscape](https://inkscape.org/) `0.92.3`

## Build forked version of streamlink which has --ffmpeg-dkey option for DRM content
```sh
$ git clone https://github.com/imrsaleh/windows-builds_on_windows.git
$ cd windows-builds_on_windows
$ pip install virtualenv
$ virtualenv venv
$ source venv/Scripts/activate
$ pip install -r requirements.txt
$ ./build-installer-windows.sh "py313-x86_64" "https://github.com/imrsaleh/streamlink.git" "master"
```

### Credits

* [Streamlink Project](https://github.com/streamlink)
