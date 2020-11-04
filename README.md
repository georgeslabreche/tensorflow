## What happened here?

This respository has been hijacked to build the image classification program used by the SmartCamLuvsU app on the European Space Agency's [OPS-SAT](https://www.esa.int/Enabling_Support/Operations/OPS-SAT_your_flying_laboratory) spacecraft. This is in no means a permanent solution. It is an overklill hack to take advantage of TensorFlow's Bazel build system so that the program can be quickly compiled for the spacecraft's ARM32 architecture. 

## How do I build and deploy?

The image classification source code is in the `//tensorflow/lite/c` directory. The commands in the following instructions are executed from this repository's home directory.

### Compile

During development you might want build the program with the default GNU toolchain so that you can run it in on your local environment:

```
bazel build -c opt //tensorflow/lite/c:image_classifier
```

You can build for the spacecraft's ARM32 architecture once you are ready to uplink the program to space:

```
bazel build --config=elinux_armhf -c opt //tensorflow/lite/c:image_classifier
```

### Cleanup
Run the cleanup script. It will collect all required files into a single folder with the appropriate file structure:

```
./c_cleanup.sh
```

The cleanup script also writes a bash script that will create the expected symbolic links for the program. This script needs to be executed on the spacecraft after installing the app.

### Deploy
Commit the bin directory created by the cleanup script into the root directory of the SmartCamLuvsU project repo. Follow the insturctions in that repo's README to deploy the app to the spacecraft.

## How do we clean this mess?

The following needs to be moved to the SmartCamLuvsU's project repository:
1. The compiled TensorFlow Lite C API library.
2. The `main.c` image classifier source code.
3. The `ujpeg.cc` and `ujpeg.h` source code for jpeg decoding.

Afterwhich, a SmartCamLuvsU build script needs to be written to compile `main.c` with the ARM32 GNU toolchain. For step 1, the TensorFlow Lite C API library can be compiled with Bazel:

```
./bazel build -c opt //tensorflow/lite/c:tensorflowlite_c
```
