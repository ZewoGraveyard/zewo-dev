zewo-dev
--------

`zewo-dev` is a tool to make developing Zewo modules and tracking their status easier.

The tool manages **only** modules including a `Package.swift` file, but checks out all the repositories in the Zewo organization.

## Installing
* Tool is built using Ruby.
* Requires you to have access to Github

`gem install zewo-dev`

## Getting started
Create a directory in which you want to put all Zewo repositories, and move into it. Then run `zewodev init`. This will clone all repositories in the Zewo organization.

```
mkdir zewo-development
cd zewo-development
zewodev init
```

## Xcode development

> A new method has been implemented to simplify the setup process `zewodev setup_osx_dev`. This command removes the need to perform the steps below.

Run `zewodev make_projects` to generate Xcode projects for all Swift modules. Every time this command is run, the previously generated projects are removed entirely. Xcode files should not be pushed. Add `XcodeDevelopment` to `.gitignore` if not there already.

**Because the tool also adds modules as dependencies you can work on several repositories simultaneously.**

## Checking status
`zewodev status` will show you the current status of all the repositories. Red means you have uncommitted changes, green means there are no uncommitted changes.

Lastly, you'll be prompted to push your changes.

## Pulling changes
`zewodev pull` pulls changes from all repositories

## Unit testing
If you create a folder called `Tests` in the same directory as your `Sources` directory, the tool will create a `<ModuleName>-tests` target and add the test files to that target.
