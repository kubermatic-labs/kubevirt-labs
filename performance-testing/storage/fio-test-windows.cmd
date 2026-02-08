@echo off
REM FIO storage benchmark for Windows
REM Requires: fio for Windows from https://github.com/axboe/fio
REM Install via: download MSI installer from https://github.com/axboe/fio/releases

fio --filename=testfile --direct=1 --rw=randrw --bs=4k --ioengine=windowsaio --iodepth=256 --runtime=120 --numjobs=4 --time_based --group_reporting --name=iops-test-job --eta-newline=1 --size=1G

REM Cleanup test file after benchmark
del testfile 2>nul