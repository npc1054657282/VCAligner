const std = @import("std");
const vcaligner = @import("vcaligner");
const analysis = @import("analysis.zig");

pub const Candidate = struct {
    commits: vcaligner.commit_range.CommitCollection,
    created_by_agenda: usize,
    refined_by_agendas: []usize,
    compatible_agendas: []usize,
    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        self.commits.deinit(allocator);
        allocator.free(self.refined_by_agendas);
        allocator.free(self.compatible_agendas);
        self.* = undefined;
    }
    pub const Builder = struct {
        commits: vcaligner.commit_range.CommitCollection,
        created_by_agenda: usize,
        refined_by_agendas: std.ArrayListUnmanaged(usize),
        compatible_agendas: std.ArrayListUnmanaged(usize),
        pub fn toOwnedCandidate(self: *Builder, allocator: std.mem.Allocator) !Candidate {
            const refined_by_agendas = try self.refined_by_agendas.toOwnedSlice(allocator);
            errdefer self.refined_by_agendas = .fromOwnedSlice(refined_by_agendas);
            const compatiable_agendas = try self.compatible_agendas.toOwnedSlice(allocator);
            errdefer comptime unreachable;
            return .{
                .commits = self.commits,
                .created_by_agenda = self.created_by_agenda,
                .refined_by_agendas = refined_by_agendas,
                .compatible_agendas = compatiable_agendas,
            };
        }
        pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
            self.commits.deinit(allocator);
            self.refined_by_agendas.deinit(allocator);
            self.compatible_agendas.deinit(allocator);
            self.* = undefined;
        }
    };
    pub const Set = struct {
        candidates: []Candidate,
        pub fn deinit(self: Set, allocator: std.mem.Allocator) void {
            for (self.candidates) |*candidate| {
                candidate.deinit(allocator);
            }
            allocator.free(self.candidates);
        }
        pub const Builder = struct {
            candidate_builders: std.ArrayListUnmanaged(Candidate.Builder),
            pub fn toOwnedSet(self: *Set.Builder, allocator: std.mem.Allocator) !Set {
                var candidate_list: std.ArrayListUnmanaged(Candidate) = try .initCapacity(allocator, self.candidate_builders.items.len);
                errdefer {
                    for (candidate_list.items, 0..) |*candidate, idx| {
                        self.candidate_builders.items[idx] = .{
                            .commits = candidate.commits,
                            .created_by_agenda = candidate.created_by_agenda,
                            .refined_by_agendas = .fromOwnedSlice(candidate.refined_by_agendas),
                            .compatible_agendas = .fromOwnedSlice(candidate.compatible_agendas),
                        };
                    }
                    candidate_list.deinit(allocator);
                }
                for (self.candidate_builders.items) |*candidate_builder| {
                    candidate_list.appendAssumeCapacity(try candidate_builder.toOwnedCandidate(allocator));
                }
                const candidates = try candidate_list.toOwnedSlice(allocator);
                self.candidate_builders.deinit(allocator);
                return .{ .candidates = candidates };
            }
            pub fn deinit(self: *Set.Builder, allocator: std.mem.Allocator) void {
                for (self.candidate_builders.items) |*candidate_builder| {
                    candidate_builder.deinit(allocator);
                }
                self.candidate_builders.deinit(allocator);
                self.* = undefined;
            }
        };
    };
};

pub fn analyseCandidates(
    agendas: []const analysis.AgendaUnit,
    allocator: std.mem.Allocator,
) !Candidate.Set {
    var candidate_set_builder: Candidate.Set.Builder = .{ .candidate_builders = .empty };
    errdefer candidate_set_builder.deinit(allocator);
    for (agendas, 0..) |*current_agenda, current_agenda_idx| {
        var intersection_success: bool = false;
        for (candidate_set_builder.candidate_builders.items) |*candidate_builder| {
            fallthrough: switch (try candidate_builder.commits.intersectInPlace(allocator, current_agenda.commit_collection)) {
                .empty => {},
                .restricted => {
                    try candidate_builder.refined_by_agendas.append(allocator, current_agenda_idx);
                    continue :fallthrough .unchanged;
                },
                .unchanged => {
                    intersection_success = true;
                    try candidate_builder.compatible_agendas.append(allocator, current_agenda_idx);
                },
            }
        }
        if (!intersection_success) {
            var new_candidate_builder: Candidate.Builder = .{
                .commits = try current_agenda.commit_collection.dupe(allocator),
                .created_by_agenda = current_agenda_idx,
                .refined_by_agendas = .empty,
                .compatible_agendas = .empty,
            };
            errdefer new_candidate_builder.deinit(allocator);
            for (agendas[0..current_agenda_idx], 0..) |*rescreen_agenda, rescreen_agenda_idx| {
                fallthrough: switch (try new_candidate_builder.commits.intersectInPlace(allocator, rescreen_agenda.commit_collection)) {
                    .empty => {},
                    .restricted => {
                        try new_candidate_builder.refined_by_agendas.append(allocator, rescreen_agenda_idx);
                        continue :fallthrough .unchanged;
                    },
                    .unchanged => {
                        try new_candidate_builder.compatible_agendas.append(allocator, rescreen_agenda_idx);
                    },
                }
            }
            try new_candidate_builder.compatible_agendas.append(allocator, current_agenda_idx);
            try candidate_set_builder.candidate_builders.append(allocator, new_candidate_builder);
        }
    }
    return try candidate_set_builder.toOwnedSet(allocator);
}
