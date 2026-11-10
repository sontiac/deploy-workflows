# Validates a deploy.json. Prints one line per problem; prints nothing when
# the config is valid. The format is documented in README.md.

def check(cond; message): if cond then empty else message end;
def relative_path: type == "string" and length > 0 and (startswith("/") | not) and (split("/") | any(. == "..") | not);
def absolute_path: type == "string" and startswith("/") and (split("/") | any(. == "..") | not);
def nonempty_string: type == "string" and length > 0;
def unknown_keys($allowed): keys - $allowed | .[] | "unknown key \"\(.)\"";

def common_keys: ["name", "type", "host", "remote_path", "health_url", "audit_fail_on"];

def check_common:
  check(.name | type == "string" and test("^[a-z0-9][a-z0-9-]*$"); "name: required; lowercase letters, digits and dashes"),
  check(.host | nonempty_string; "host: required; the ssh host to deploy to, e.g. \"sontiac\""),
  check(.remote_path | absolute_path; "remote_path: required; an absolute path on the host"),
  check(.health_url | type == "string" and test("^https?://"); "health_url: required; an http(s) URL"),
  check(.audit_fail_on | IN("never", "low", "moderate", "high", "critical");
    "audit_fail_on: required; one of never, low, moderate, high, critical");

def check_process($i):
  if type != "object" then "processes[\($i)]: must be an object"
  else
    (
      unknown_keys(["pm2_name", "port", "working_dir", "build_cmd", "prisma_schema_dir"]),
      check(.pm2_name | nonempty_string; "pm2_name: required; the pm2 process name"),
      check(.port | type == "number" and . == floor and . > 0 and . < 65536; "port: required; the port the process listens on"),
      check(.working_dir | relative_path; "working_dir: required; a path relative to the repo root (\".\" for the root)"),
      check(.build_cmd | nonempty_string; "build_cmd: required; the shell command that builds it"),
      check((has("prisma_schema_dir") | not) or (.prisma_schema_dir | relative_path);
        "prisma_schema_dir: a path relative to the repo root; leave it out when there is no prisma")
    ) | "processes[\($i)]: \(.)"
  end;

def check_node_app:
  unknown_keys(common_keys + ["processes"]),
  check(.processes | type == "array" and length > 0; "processes: required; a non-empty array"),
  (if .processes | type == "array" then
     (.processes | to_entries[] | .key as $i | .value | check_process($i)),
     check(.processes | (map(objects | .pm2_name) | unique | length) == (map(objects) | length);
       "processes: pm2_name values must be unique")
   else empty end);

def check_static_site:
  unknown_keys(common_keys + ["working_dir", "build_cmd", "dist_dir"]),
  check(.working_dir | relative_path; "working_dir: required; a path relative to the repo root (\".\" for the root)"),
  check(.build_cmd | nonempty_string; "build_cmd: required; the shell command that builds the site"),
  check(.dist_dir | relative_path; "dist_dir: required; the build output, relative to working_dir");

if type != "object" then "the top level must be an object"
elif .type == "node-app" then check_common, check_node_app
elif .type == "static-site" then check_common, check_static_site
else "type: required; \"node-app\" or \"static-site\""
end
