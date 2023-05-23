+++
title = "Feature Switch Rule Definitions"
date = "2023-05-22T20:16:47.433Z"
header_img = ""
toc = "2023-05-22T20:16:47.433Z"
tags = [ "guide", "feature-switches" ]
categories = [ ]
series = [ "Feature Switches" ]
comment = true
+++

## Feature switch syntax

A feature switch can be defined in many different ways, each with their own pros and cons.

Before deciding on what a feature switch looks like, you'll probably want to ask yourself a few questions:
* Do I want to store feature switches in a database or on a filesystem (eg, in git)?
  * A database is automatically distributed, making the switches accessible anywhere the database can be accessed. While storing in git would mean you need a way to distribute the files to any production server that needs them.
  * Storing in git means that you can take advantage of code review processes to gate changes, but it might also slow down how quickly those changes are rolled out.
  * Storing in git allows developers to test their feature switches in a local file without having to use a staging database.
  * Git logs provide a built in audit log of changes, whereas this is something that you'd need to build yourself if they were stored in a DB.
* Should a feature switch be able to change multiple values?
* What sort of metadata should I store with my feature switches?
  * Do I need ownership information? A description?
* Where do default values get stored?
* Should there be any logical grouping of feature switch rules? (eg, if there are multiple rules that all impact the same feature names)
* How do we handle the case where multiple rules match, but set conflicting values for the same feature name?

For this series, we will:
1. Store our feature switches on a filesystem in [YAML](https://en.wikipedia.org/wiki/YAML) format
2. Allow multiple rules to exist in a single file
3. Allow a single rule to change multiple feature switch values
4. Allow name/description as our only metadata
5. Store default values for features along with the switches that set them
6. Specify an explicit priority for dealing with conflicts

Let's take a moment to walk through a skeleton feature switch file.
```yaml
fs_group:
  name: "Color scheme based on locale + device"
  feature_switches:
    - description: "White background for Canadian users"
      priority: 49
      featureValues:
        - backgroundColor: "white"
        - foregroundColor: "red"
      rule:
        <rule definition intentionally left for later>
    - description: "Red background for older iOS users"
      priority: 50
      featureValues:
        - backgroundColor: "red"
      rule:
        <rule definition intentionally left for later>
```

Each file defines a group of logically-connected feature switch rules. Above, we have 2 separate rules in a single file that both deal with changing the color scheme. The first rule targets Canadian users and sets both a `backgroundColor` and `foregroundColor`. The second rule targets iOS users running an older version of our app and only sets the `backgroundColor`. We've assigned them a priority, where higher numbers take precedence if more than one rule tries to assign a value to the same feature.

However, there's a little bit of nuance in dealing with conflicts here. What do we do if the user is both Canadian, and using an older iOS device? Technically, they only conflict on the background color. However, if we assign the foregroundColor from the first rule (`"red"`), and the backgroundColor from the second rule (also `"red"`!), we'll run into a terrible user experience (and perhaps unexpected behavior from the developer's point of view).

We can solve the problem by imposing a new restriction:
>Every rule in the same group must provide values for the same set of features. Meaning if one rule in the group provides a `backgroundColor`, then all rules must provide a `backgroundColor`.

With this restriction in place, we can further simplify things by specifying default values for each of those features at the top-level of our group. Now rules must either specify all values explicitly, or fallback on default values implicitly.

```yaml
fs_group:
  name: "Color scheme based on locale + device"
  defaults:
    - backgroundColor: "black"
    - foregroundColor: "white"
  feature_switches:
    - description: "White background for Canadian users"
      priority: 49
      featureValues:
        - backgroundColor: "white"
        - foregroundColor: "red"
      rule:
        <rule definition intentionally left for later>
    - description: "Red background for older iOS users"
      priority: 50
      featureValues:
        - backgroundColor: "red"
      rule:
        <rule definition intentionally left for later>
```

Older iOS users will now have a `backgroundColor` of `"red"` and a `foregroundColor` of `"white"`, thanks to our default values.

## Rule definitions

As mentioned in <a href={{< relref "/posts/feature-switches-intro" >}}>Part 1</a>, our eventual goal is to take our rule definitions and convert them into a graph containing many queries, where each query can be represented as a tree.

![Query Tree Combined](/img/feature-switches/part-1-query-tree-combined.png)

If we modify things slightly, we can actually visualize each query as an [expression tree](https://en.wikipedia.org/wiki/Binary_expression_tree), which will help us when it comes time to defining a storage format and parsing these queries.

![Expression Tree](/img/feature-switches/part-2-expression-tree.png)

We have several options for how we format our rules, each with pros and cons that depend on the ecosystem we're building on top of.

### Defining our rules in a tree-like format

One of the easiest formats we can parse is one that already looks like an expression tree.

```yaml
fs_group:
  name: "Color scheme based on locale + device"
  defaults:
    - backgroundColor: "black"
    - foregroundColor: "white"
  feature_switches:
    - description: "White background for CA users + newer iOS users"
      priority: 49
      featureValues:
        - backgroundColor: "white"
        - foregroundColor: "red"
      rule:
        or:
          - and:
              - "==": ["device", "iOS" ]
              - ">=": ["appVersion", "2.0.0"]
          - "==": ["countryCode", "CA"]
```

This format assumes that each operator will contain a 2 item list (its operands). Building an expression tree from this format is fairly trivial. We would just need to traverse our rule, adding a new node for each operator and then adding each item in an operator's list as its children.

While this format optimizes the parse codepath, it can be cumbersome for humans to read and write. This might be a good format if you have the right tooling to support it. You would likely want:
1. A UI that takes the rules in a more human-friendly format and then does the conversion afterwards, and/or
2. Robust tooling for developers to test and verify their rules before submitting them

### Using prefix notation

Another easy-to-parse format is prefix notation, where operators appear before their operands. In mathematical terms, `A + B * C` becomes `+ A * B C`. This again fits naturally into an expression tree, since each node in the tree is followed by it's left and right children.

Let's take a look at what that might look like using the same example.

```yaml
fs_group:
  name: "Color scheme based on locale + device"
  defaults:
    - backgroundColor: "black"
    - foregroundColor: "white"
  feature_switches:
    - description: "White background for CA users + newer iOS users"
      priority: 49
      featureValues:
        - backgroundColor: "white"
        - foregroundColor: "red"
      rule: "OR AND == device 'iOS' >= appVersion '2.0.0' == countryCode 'CA'"
```

This format again optimizes the parse codepath. Since each operator is followed by its 2 children, parsing would mean: (1) tokenizing the rule expression, (2) adding the operator as a node in our expression tree, and then (3) adding the next two tokens as its children.

We can make the expression a little more readable by adding some parentheses and commas. Doing so makes it a little easier to see which operators belong to which operand:
`OR(AND(==(device, 'iOS'), >=(appVersion, '2.0.0')), ==(countryCode, 'CA'))`

In my opinion, this still is hard to reason about.

### Back to infix notation

I specified our example rules in <a href={{< relref "/posts/feature-switches-intro" >}}>Part 1</a> using infix notation for a reason: it's the same notation that most people are familiar with already.

```yaml
fs_group:
  name: "Color scheme based on locale + device"
  defaults:
    - backgroundColor: "black"
    - foregroundColor: "white"
  feature_switches:
    - description: "White background for CA users + newer iOS users"
      priority: 49
      featureValues:
        - backgroundColor: "white"
        - foregroundColor: "red"
      rule: "countryCode == 'CA' OR (device == 'iOS' AND appVersion >= '2.0.0')"
```

Definitely easier for humans to reason about! We are going to choose to optimize for human readability and move forward with infix notation.

The problem is that it is not trivial to parse. Luckily there are plenty of libraries out there to help with this. In the next article, we'll define a formal grammar for our rule expressions and build a parser that formats our rules into expression trees.
