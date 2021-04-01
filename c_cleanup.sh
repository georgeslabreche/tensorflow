#!/bin/bash

arch="armhf"
#arch="k8"

app_name="opssat_smartcam"
program_filename="image_classifier"

# Clear deployment directory.
rm -rf deploy

# Path for shared objects directory in SEPP.
so_sepp_dir_path="/home/root/georges/apps/$app_name"

# Create executable bin directory.
deploy_dir="deploy/apps/$app_name"
deploy_bin_dir="bin/tensorflow/lite/c"
exec_sepp_dir="$deploy_dir/$deploy_bin_dir"

# Directory path for required shared objects.
so_bazel_out_dir_path="bazel-out/$arch-opt/"
so_bazel_in_dir_path="bazel-bin/_solib_$arch"


# Path of program executable.
exec_local_filepath="${so_bazel_out_dir_path}$deploy_bin_dir/$program_filename"

mkdir -p $exec_sepp_dir

# Create .so symlink directory.
so_deploy_dir="$deploy_dir/bin/_solib_$arch"
mkdir "$so_deploy_dir"

echo "fetch required .so files and process symbolic links..."

# Process symbolic links.
for symlink in $so_bazel_in_dir_path/*
do
  ###
  # Fetch all of the required .so files and copy them to the deploy bin directory.
  ###
  
  # Get the path of the .so file.
  so_local_filepath=$(readlink -f "$symlink")
  
  # Remove bazel .cache directory path.
  so_rel_filepath=`echo ${so_local_filepath} | sed -e 's/.*-opt//g'`
  
  # Recreate .so directory structure in deployment directory.
  so_dir="$(dirname "$deploy_dir${so_rel_filepath}")"
  
  mkdir -p $so_dir

  # Copy .so file.
  cp $so_local_filepath "$so_dir/"
  
  ###
  # Write bash script that will crate the required symbolic links in the SEPP.
  ###
  
  # Get filename of symbolic link
  symlink_filename="${symlink##*/}"
  
  # Define the SEPP path of the symbolic link.
  so_sepp_filepath="$so_sepp_dir_path$so_rel_filepath"

  # Create the bash script that will be used to create the required symbolic links on SEPP.
  # We do this because symbolic links cannot be archived so we need to recreate them in the development environment.
  echo "ln -s $so_sepp_filepath $so_sepp_dir_path/bin/_solib_$arch/$symlink_filename" >> deploy/create_symlinks.sh
done

# Make created bash script an executable file.
chmod +x deploy/create_symlinks.sh

echo "fetch executable..."
cp $exec_local_filepath $exec_sepp_dir"/"

# Make the exectuable file executable
chmod +x $exec_sepp_dir"/$program_filename"

echo "tar..."
tar -czvf deploy.tar.gz deploy/*

echo "done."
