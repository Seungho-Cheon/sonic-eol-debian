-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Format: 3.0 (quilt)
Source: protobuf
Binary: ruby-google-protobuf, libprotobuf32, libprotobuf-lite32, libprotobuf-dev, libprotoc32, libprotoc-dev, protobuf-compiler, python3-protobuf, libprotobuf-java, elpa-protobuf-mode, php-google-protobuf
Architecture: any all
Version: 3.21.12-3
Maintainer: Laszlo Boszormenyi (GCS) <gcs@debian.org>
Homepage: https://github.com/google/protobuf/
Standards-Version: 4.6.1
Testsuite: autopkgtest
Testsuite-Triggers: build-essential, default-jdk, make, pkg-config, python3, zlib1g-dev
Build-Depends: debhelper-compat (= 13), dh-elpa [amd64 arm64 armel armhf i386 mips64el mipsel ppc64el s390x hppa ppc64 riscv64 sh4 sparc64 x32], zlib1g-dev, libgmock-dev <!nocheck>, libgtest-dev <!nocheck>, dh-sequence-python3 <!nopython>, python3-all:any <!nopython>, libpython3-all-dev <!nopython>, python3-setuptools <!nopython>, python3-six <!nopython>, xmlto, unzip <!nocheck>, rake-compiler <!noruby>, gem2deb <!noruby>, pkg-php-tools (>= 1.7~)
Build-Depends-Indep: ant, default-jdk, maven-repo-helper, libguava-java, libgoogle-gson-java
Package-List:
 elpa-protobuf-mode deb editors optional arch=all
 libprotobuf-dev deb libdevel optional arch=any
 libprotobuf-java deb java optional arch=all
 libprotobuf-lite32 deb libs optional arch=any
 libprotobuf32 deb libs optional arch=any
 libprotoc-dev deb libdevel optional arch=any
 libprotoc32 deb libs optional arch=any
 php-google-protobuf deb php optional arch=all
 protobuf-compiler deb devel optional arch=any
 python3-protobuf deb python optional arch=any profile=!nopython
 ruby-google-protobuf deb ruby optional arch=any profile=!noruby
Checksums-Sha1:
 7aec582dff3ab784ca7d2a2c99e59c64e8866fb5 5141502 protobuf_3.21.12.orig.tar.gz
 c3d325aaf807949034e749a2c81af5de9c8d10c7 34232 protobuf_3.21.12-3.debian.tar.xz
Checksums-Sha256:
 930c2c3b5ecc6c9c12615cf5ad93f1cd6e12d0aba862b572e076259970ac3a53 5141502 protobuf_3.21.12.orig.tar.gz
 531979ef0d5a84cb089cafbb6e2313caf585e8d3a0eb154036f73d7e72f63a89 34232 protobuf_3.21.12-3.debian.tar.xz
Files:
 d38562490234d8080bdbe8eb7baf937a 5141502 protobuf_3.21.12.orig.tar.gz
 f457e44218a7d4cc7b7ab0ed696096e3 34232 protobuf_3.21.12-3.debian.tar.xz
Ruby-Versions: all

-----BEGIN PGP SIGNATURE-----

iQIzBAEBCgAdFiEEfYh9yLp7u6e4NeO63OMQ54ZMyL8FAmQyWlwACgkQ3OMQ54ZM
yL+UgxAAi1fAXRLnD5VHksO6y0jOyEnsoQlp9hdrqhwh1K6dKGJfffE2Hf7hNCsb
NIpj0f8bAxnbW4SWJpKH4F3P7Bzl3XZogGoeW2C2EOxY0aH92koFHJ/0ur7dVFJa
PbeONDIVFhpwDtrH+EGcunblPwkUTzn0QJVOSRniNjvCuO1ZgQLG3knOUVqV3gU7
z7qkdCSud7CP3chmnsy2UtrlQttJk/G5w7xYW8mXO3sMaUA0kx6niH5hZTXl3n0i
muZ7fTd8OA0yvmh/609DbKmK2g1DRlDT8JhC+SJ+7xY/E4Tf31PwttlYm2Ht+XrZ
LeV+YMpkAhQ348cu7A4Ok9m+aEf48HP4waqloJ4PBI8Z5ZOW19Tz+bWM75Z3WqNc
GaiamNIgPN2suJSSHYmQx2rcjd5CNIoV020nCTcZG8pn3ly2iNCeUW9NiqUs0du6
pM+OiNW1DqxwCJj/++P/sBh2lyVe8peMIYEGx1PX2xFA5Fj919RTOJeDDwhAv4Jj
oDv6shkUcsuUsUtUnzSxrxPZsRWLSQEISTuDA4RXVaTgiiuMixPAmMSum2TGjxCJ
Yye5oHiK76AAdi04jFjLfnogpWc4lJaptdr9OZc8x9O3Mzq8hRSF0CHGj0wbLTyT
PzXZRYUt1jHi6g0+XEJP3F4/7jXDPurvAitmUafIvEXK0U9kWrQ=
=rcK9
-----END PGP SIGNATURE-----
