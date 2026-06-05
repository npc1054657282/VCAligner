const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
pub fn main_parse_task(repo: *c.git_repository) void {
    defer c.git_repository_free(repo);
}
