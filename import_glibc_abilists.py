#!/usr/bin/env python3
import sys
import os
import subprocess
import pathlib
import re
import shutil

# target glic versions that will be used to copy abilist files
TARGET_VERSIONS=(
  "2.23",
  "2.24",
  "2.25",
  "2.26",
  "2.27",
  "2.28",
  "2.29",
  "2.30",
  "2.31",
  "2.32",
  "2.33",
)

def main():
  if len(sys.argv) < 2:
    print("please provide glibc repository directory")
    exit(1)

  GLIBC_REPO_PATH=os.path.realpath(sys.argv[1])
  if not os.path.isdir(GLIBC_REPO_PATH):
    print("provided glibc path is not a directory")
    exit(1)

  PWD = os.getcwd()

  for version in TARGET_VERSIONS:
    version_path = f"{PWD}/glibc/{version}"

    if not os.path.exists(version_path):
      os.mkdir(version_path)

    # checkout specific glibc version in provided glibc repo directory
    git_checkout = subprocess.run(["git", "-C", GLIBC_REPO_PATH, "checkout", f"glibc-{version}"])
    if git_checkout.returncode != 0:
      print(f"checkout glibc-{version}: {git_checkout.stderr}")
      exit(git_checkout.returncode)

    # find and copy all .abilist files
    for path in pathlib.Path(GLIBC_REPO_PATH).rglob("*.abilist"):
      p = str(path.absolute())
      path_without_prefix = p.replace(GLIBC_REPO_PATH, "")

      prefix = PWD+os.sep+"glibc"+os.sep+version
      out_dir = prefix + re.sub(pattern="\/[^/]*$", repl="", string=path_without_prefix)
      out_file = prefix + path_without_prefix

      # create path if it does not exist
      if not os.path.exists(out_dir):

        pathlib.Path(out_dir).mkdir(parents=True)

      # copy files
      shutil.copy(path, out_file)

    print(f"copied .abilist files for glibc-{version}")

if __name__ == "__main__":
  main()
