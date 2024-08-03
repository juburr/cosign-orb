# 

<div align="center">
  <img align="center" width="320" src="assets/logos/cosign-orb-logo.png" alt="Cosign Orb">
  <h1>CircleCI Cosign Orb</h1>
  <i>An orb for simplifying Cosign installation and use within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/cosign-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/cosign-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/cosign-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/cosign-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/cosign-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an unofficial Cosign orb used for installing Cosign in your CircleCI pipeline, signing container images, and verifying container images. Contributions are welcome!

### Installation

Use `cosign-orb` to handle installation of Cosign within your CircleCI pipeline. You can then use the `cosign` command anywhere within your job. Caching is supported if you'd like to prevent downloading CircleCI on successive runs of your pipeline, though download and installation is normally extremely fast.

Provenance: Cosign is installed directly from the official Github [releases page](https://github.com/sigstore/cosign/releases/) for the Cosign project. A future version of this orb will also provide checksum verification of every download.

```yaml
version: 2.1

orbs:
  cosign: juburr/cosign-orb@0.1.4

parameters:
  cimg_base_version:
    type: string
    default: "stable-20.04"
  cosign_version:
    type: string
    default: "2.2.3"

jobs:
  sign_container:
    docker:
      - image: cimg/base:<< pipeline.parameters.cimg_base_version >>
    steps:
      - checkout
      - cosign/install:
          caching: true
          version: << pipeline.parameters.cosign_version>
      - run:
          name: Run Cosign Commands
          command: |
            cosign version
```