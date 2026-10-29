#!/bin/bash
# Records the simulator while the UI test drives the demo. Output: take.mp4, take.log, rec_start.txt
SIM=A45719F1-1DD1-42CC-9232-459774F0B719
cd "$(dirname "$0")"
rm -f take.mp4
xcodebuild build-for-testing -project DemoDriver.xcodeproj -scheme Driver -destination "id=$SIM" -derivedDataPath dd -quiet
xcrun simctl io $SIM recordVideo --codec h264 --force take.mp4 2> rec.err &
REC=$!
# recordVideo prints "Recording started" once frames are flowing
for i in $(seq 100); do grep -q "Recording started" rec.err && break; sleep 0.1; done
python3 -c "import time;print('%.3f'%time.time())" > rec_start.txt
xcodebuild test-without-building -project DemoDriver.xcodeproj -scheme Driver -destination "id=$SIM" -derivedDataPath dd > take.log 2>&1
kill -INT $REC; wait $REC
grep -E "SCENE|READY|END|OVERRUN|TEST |error|Assert" take.log | grep -v "^\s*t =" | head -40
