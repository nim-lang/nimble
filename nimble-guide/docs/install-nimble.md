# Installing Nimble

Nimble is bundled with [Nim](https://nim-lang.org).
This means that you should have Nimble installed already, as long as you have
the latest version of Nim installed as well.
Because of this, it is very likely that **you do not need to install Nimble manually**.

In case you still want to install Nimble manually, you can follow these installation instructions:


### Using koch

The ``koch`` tool is included in the Nim distribution and [repository](https://github.com/nim-lang/Nim/blob/devel/koch.nim).
Simply navigate to the location of your Nim installation and execute the following command to compile and install Nimble:

```
./koch nimble
```

This will clone the Nimble repository, compile Nimble and copy it into
Nim's bin directory.



### Using Nimble

In most cases you will already have Nimble installed, you can install a newer
version of Nimble by simply running the following command:

```
nimble install nimble
```

This will download the latest release of Nimble and install it on your system.

Note that you must have `~/.nimble/bin` in your `PATH` for this to work.
If you're using [choosenim](https://github.com/dom96/choosenim) then you likely already have this set up correctly.

