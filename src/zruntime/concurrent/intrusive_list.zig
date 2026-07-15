/// Link embedded in a caller-owned node. A linked node must not be freed or moved.
pub const Link = struct { prev: ?*Link = null, next: ?*Link = null, linked: bool = false };

/// Non-owning intrusive doubly linked list. It does not reclaim nodes and therefore does not solve ABA; callers must synchronize removal and reclamation.
pub const IntrusiveList = struct {
    head: ?*Link = null,
    tail: ?*Link = null,
    len: usize = 0,
    pub fn isEmpty(self: *const IntrusiveList) bool {
        return self.head == null;
    }
    pub fn pushBack(self: *IntrusiveList, link: *Link) !void {
        if (link.linked) return error.AlreadyLinked;
        link.prev = self.tail;
        link.next = null;
        if (self.tail) |tail| tail.next = link else self.head = link;
        self.tail = link;
        link.linked = true;
        self.len += 1;
    }
    pub fn pushFront(self: *IntrusiveList, link: *Link) !void {
        if (link.linked) return error.AlreadyLinked;
        link.next = self.head;
        link.prev = null;
        if (self.head) |head| head.prev = link else self.tail = link;
        self.head = link;
        link.linked = true;
        self.len += 1;
    }
    pub fn remove(self: *IntrusiveList, link: *Link) !void {
        if (!link.linked) return error.NotLinked;
        self.removeLinked(link);
    }
    fn removeLinked(self: *IntrusiveList, link: *Link) void {
        if (link.prev) |prev| prev.next = link.next else self.head = link.next;
        if (link.next) |next| next.prev = link.prev else self.tail = link.prev;
        link.* = .{};
        self.len -= 1;
    }
    pub fn popFront(self: *IntrusiveList) ?*Link {
        const link = self.head orelse return null;
        self.removeLinked(link);
        return link;
    }
    pub fn popBack(self: *IntrusiveList) ?*Link {
        const link = self.tail orelse return null;
        self.removeLinked(link);
        return link;
    }
};
