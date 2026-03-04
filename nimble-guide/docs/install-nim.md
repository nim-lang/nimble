# Installing Nim

Nimble can be used to install Nim globally and manage global Nim versions. In this quality, it's direct replacement for tools like [choosenim](https://github.com/dom96/choosenim) and [grabnim](https://codeberg.org/janAkali/grabnim).

1. [Install Nimble](./install-nimble.md).

1. Install the latest Nim globally:

    ```shell
    $ nimble install -g nim
    ```

    If you need a specific version:

    ```shell
    $ nimble install -g nim@2.2.6
    ```

1. To set up development environment, install nimlangserver and nph globally:

    ```shell
    $ nimble install -g nimlangserver nph
    ```
